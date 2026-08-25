# frozen_string_literal: true

module Hitch
  # POST /oauth/device_authorization — RFC 8628 §3.1: mint a device grant
  # and hand back the code pair a headless client shows its human.
  #
  # Public endpoint, like tokens: the caller is a machine with no session.
  # One thing it deliberately never does is fetch client metadata — every
  # CIMD fetch in this gem has a signed-in, rate-limited actor, and this
  # endpoint has neither, so a CIMD-shaped client_id is accepted as a
  # string here and resolved on /activate, where the approving person is
  # the actor.
  class DeviceAuthorizationsController < Hitch::PublicEndpointController
    include Hitch::CorsSupport
    include Hitch::OauthFormAdmission
    include Hitch::UriValidation
    include Hitch::ClientResolution
    include Hitch::DeviceAuthorizationGate

    DEVICE_PARAMETER_NAMES = %i[client_id client_secret scope resource].freeze

    def create
      unless request.media_type == Hitch::OauthRequestParameters::FORM_MEDIA_TYPE
        return oauth_error("invalid_request", "device authorization requests must use application/x-www-form-urlencoded")
      end
      return unless admit_mint_rate!

      oauth = oauth_parameters(*DEVICE_PARAMETER_NAMES, form_only: true)
      resource = require_canonical_resource(oauth[:resource])
      return unless resource

      authentication = resolved_client_authentication(oauth)
      client_id = authentication.client_id
      # A device grant needs a client somebody real vouches for: a
      # metadata document (its host is earned by serving it), or a
      # confidential client the operator registered — whose row records that
      # provenance and which just authenticated by its secret. A client that
      # only vouched for itself via open registration is the §5.4 phishing
      # shape, whether or not DCR gave it a secret, and cannot mint. A
      # registered row decides first, exactly as /activate classifies, so
      # nothing can mint a grant the screen would never approve.
      live_client = Hitch::Client.find_by(client_id: client_id)
      voucher_auth_method = case authentication.token_endpoint_auth_method
      when "client_secret_basic"
        if authentication.operator_registered &&
            live_client&.operator_registered_confidential_client?
          "client_secret_basic"
        end
      when "none"
        if !authentication.registered_client && live_client.nil? &&
            Hitch::ClientIdMetadata.reference?(client_id)
          "none"
        end
      end
      unless voucher_auth_method == authentication.token_endpoint_auth_method
        return oauth_error(
          "invalid_client",
          "device authorization requires a client metadata document or an operator-registered client",
          :unauthorized
        )
      end

      grant = Hitch::DeviceGrant.mint!(
        client_id: client_id,
        scopes: oauth[:scope],
        resource_uri: resource,
        token_endpoint_auth_method: authentication.token_endpoint_auth_method
      )
      render_device_authorization(grant)
    end

    private

    def client_authentication_realm
      "oauth/device_authorization"
    end

    def admit_mint_rate!
      hitch_admit_rate!("Device authorization") do
        Hitch::DeviceAuthorizationRateLimit.check_mint!(remote_ip: request.remote_ip)
      end
    end

    # §3.2. verification_uri comes from the configured issuer, never the
    # request: a Host-header alias must not leak into a URI a person types.
    def render_device_authorization(grant)
      user_code = Hitch::DeviceGrant.display_user_code(grant.raw_user_code)
      activate = "#{issuer_url}/activate"
      render json: {
        device_code: grant.raw_device_code,
        user_code: user_code,
        verification_uri: activate,
        verification_uri_complete: "#{activate}?user_code=#{user_code}",
        expires_in: Hitch.configuration.device_code_lifetime_seconds,
        interval: Hitch.configuration.device_authorization_interval_seconds
      }
    end

    # RFC 6749 §5.1's non-cacheable rule, applied to the code pair for the
    # same reason it applies to tokens.
    def prepare_oauth_form_response!
      hitch_no_store!
    end

    def reject_oversized_oauth_form_body!
      oauth_error(
        "invalid_request",
        "device authorization request body exceeds #{MAX_REQUEST_BODY_BYTES} bytes",
        :content_too_large
      )
    end
  end
end
