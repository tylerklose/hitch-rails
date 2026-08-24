# frozen_string_literal: true

module Hitch
  # GET /activate  — enter a device code (RFC 8628 §3.3)
  # POST /activate — verify the code, then approve or deny
  #
  # The one browser piece of the device flow. Session-authenticated through
  # the host's ApplicationController like the consent screen: the host's
  # sign-in gates it, and current_principal is who the approval binds.
  #
  # The page's words are part of the security boundary (§5.4): the flow is
  # "a stranger asks you to approve a code", so the screen says plainly that
  # a code should only be entered by the person who asked a device for it,
  # and a ?user_code= prefill only fills the field — approving always takes
  # the person's own submit.
  class ActivationsController < Hitch::ApplicationController
    include Hitch::OauthFormAdmission
    include Hitch::DeviceAuthorizationGate

    # Same declaration and reasoning as the consent POST: state-changing,
    # session-authenticated, so it must not depend on the host having
    # forgery protection enabled. Guarded for API-only host bases.
    protect_from_forgery with: :exception if respond_to?(:protect_from_forgery)

    # This is a page a person is looking at: every malformed input — a
    # blank code, a doctored decision — answers with the form and a plain
    # sentence, never the JSON dialect the inherited rescue speaks.
    rescue_from Hitch::OauthRequestParameters::Invalid do
      render_new alert: "Enter the code your device is showing."
    end

    before_action do
      # A page for a person, in exactly one dialect: a .json path or a
      # JSON Accept header must render the HTML answer, not a
      # MissingTemplate 500.
      request.format = :html
      @brand_name = Hitch.configuration.brand_name
    end

    def new
      return unless admit_oauth_endpoint!
      return require_principal! unless current_principal

      # Prefill from verification_uri_complete. Display only — §5.4 wants
      # the person to see the code and confirm it matches their device, so
      # a prefilled form still submits by hand.
      @user_code = DeviceGrant.display_user_code(params[:user_code])
    end

    def create
      return require_principal! unless current_principal

      oauth = oauth_parameters(:user_code, :decision, form_only: true)
      # Absent field, same answer as a blank one — and before the quota:
      # neither is a guess.
      return render_new(alert: "Enter the code your device is showing.") if oauth[:user_code].blank?
      return unless admit_verification_rate!

      grant = DeviceGrant.find_pending_by_user_code(oauth[:user_code])
      return unknown_code unless grant

      case oauth[:decision]
      when nil then confirm(grant, oauth[:user_code])
      when "approve" then approve(grant, oauth[:user_code])
      when "deny" then deny(oauth[:user_code])
      else
        render_new alert: "Something went wrong with that submission. Enter the code again."
      end
    end

    private

    # A signed-out visitor following verification_uri_complete must not
    # leave the live user code sitting in the host's session store for the
    # code's whole life. They retype it after signing in — it is on the
    # device screen in front of them, which §5.4 wants them checking
    # anyway; a signed-in visitor keeps the prefill.
    def return_to_after_authenticating_url
      request.base_url + request.path
    end

    # Verification is the brute-force surface RFC 8628 §5.1 rate-limits, and
    # the decision POST carries the code too, so every branch of create sits
    # behind this. Checked per signed-in principal, after authentication —
    # anonymous traffic cannot drain a person's budget — and after parsing:
    # a blank or malformed submission is not a guess and spends none either.
    # Not hitch_admit_rate!: this refusal is a page for a person, not an
    # OAuth error body.
    def admit_verification_rate!
      Hitch::DeviceAuthorizationRateLimit.check_verification!(principal: current_principal)
      true
    rescue Hitch::RateLimitStore::Exceeded => error
      response.headers["Retry-After"] = error.retry_after.to_s
      render_new alert: "Too many attempts. Wait a minute and try again.", status: :too_many_requests
      false
    rescue Hitch::RateLimitStore::Unavailable
      render_new alert: "Code entry is temporarily unavailable. Try again shortly.",
        status: :service_unavailable
      false
    end

    def confirm(grant, user_code, activation: nil)
      @activation = activation || DeviceActivation.new(grant, principal: current_principal)
      @user_code = DeviceGrant.display_user_code(user_code)
      render :confirm
    end

    def approve(grant, user_code)
      activation = DeviceActivation.new(grant, principal: current_principal)
      # No Approve for a client that cannot be verified right now. The
      # grant is live and pending, so answer with the honest confirm
      # screen — "used or expired" would be false, and the failure may be
      # transient (a rate-limited or momentarily unreachable document).
      # The same activation is threaded through, so the screen shows the
      # state this decision was refused on.
      return confirm(grant, user_code, activation: activation) if activation.unverified?

      decided = DeviceGrant.approve!(
        user_code: user_code,
        principal: current_principal,
        client_name: activation.audit_client_name
      )
      return unknown_code unless decided

      @decision = :approved
      render :done
    end

    def deny(user_code)
      return unknown_code unless DeviceGrant.deny!(user_code: user_code)

      @decision = :denied
      render :done
    end

    # One message for never-existed, expired, and already-decided alike: a
    # more specific answer would tell a guesser which codes are live.
    def unknown_code
      render_new alert: "That code isn't waiting for approval. " \
        "It may have expired or already been used — ask your device for a fresh one."
    end

    # Assigns everything the template needs itself: some callers run from
    # admission, before the before_action.
    def render_new(alert:, status: :unprocessable_entity)
      request.format = :html
      @alert = alert
      @user_code = nil
      @brand_name = Hitch.configuration.brand_name
      render :new, status: status
    end

    def preserve_oauth_authenticity_token?
      true
    end

    def reject_oversized_oauth_form_body!
      render_new alert: "That submission was too large. Enter just the short code your device is showing.",
        status: :content_too_large
    end
  end
end
