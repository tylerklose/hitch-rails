# frozen_string_literal: true

module Hitch
  # All gem controllers inherit from the host's ApplicationController so
  # the host's authentication concern, layout, helpers, and middleware
  # apply automatically. The gem only adds OAuth-specific behavior on
  # top.
  class ApplicationController < ::ApplicationController
    include Hitch::HostValidation
    include Hitch::IssuerUrl
    include Hitch::OauthParameterValidation

    # Opt out of the host's blanket authentication-enforcement callback.
    # Rails 8's built-in `bin/rails g authentication` adds a global
    # `before_action :require_authentication` to the host's
    # ApplicationController, which this consent controller inherits. That
    # callback redirects unauthenticated visitors to the host's sign-in
    # via `new_session_path` — but evaluated inside the isolated engine's
    # routing context that helper doesn't resolve, raising
    # UrlGenerationError before the gem's own logic runs. The consent
    # screen does its OWN principal resolution (current_principal +
    # require_principal!, which honors config.login_path), so it must not
    # be pre-empted. `raise: false` makes this a no-op for hosts that
    # don't define the callback (Devise, plain apps, etc.).
    skip_before_action :require_authentication, raise: false

    # Resolve the current authenticated principal.
    #
    # 1. Call the host-configured method (default :current_user) if the
    #    host defines it — covers Devise, has_secure_password apps, and
    #    anything that exposes a current_user-style helper.
    # 2. Otherwise fall back to Rails 8's built-in authentication
    #    generator, which exposes the signed-in user as Current.user
    #    (delegated from Current.session) and defines NO current_user
    #    controller method. Without this fallback, a stock Rails 8 auth
    #    app would treat every visitor as unauthenticated and the consent
    #    screen would never render.
    #
    # Returns nil when neither resolves — the controllers handle nil as
    # "unauthenticated".
    def current_principal
      method_name = Hitch.configuration.principal_method
      return send(method_name) if respond_to?(method_name, true)

      # Rails 8 built-in auth exposes the signed-in user as Current.user,
      # populated by the host's `resume_session` — which normally runs
      # inside the `require_authentication` before_action that we skip (it
      # redirects via a host route that doesn't resolve in the engine).
      # So resume the session ourselves before reading Current.user;
      # without this, a signed-in user looks unauthenticated here and the
      # consent screen loops back to login. `resume_session` is idempotent
      # (Current.session ||= …); guarded for hosts that don't define it.
      resume_session if respond_to?(:resume_session, true)
      return Current.user if defined?(Current) && Current.respond_to?(:user)

      nil
    end

    private

    def require_principal!
      # Remember where the user was headed so the host's auth flow returns
      # them here after login. Rails 8's built-in authentication reads
      # session[:return_to_after_authenticating] in after_authentication_url;
      # normally its own require_authentication callback sets this, but
      # these controllers skip that callback (see above) and redirect to
      # login_path themselves, so the return location is set here. Harmless
      # for hosts that never read the key. Only meaningful on a GET render —
      # a POST without a session isn't a real flow.
      session[:return_to_after_authenticating] = return_to_after_authenticating_url if request.get?

      path = Hitch.configuration.login_path
      target = path.respond_to?(:call) ? path.call(request) : path

      if target.present?
        redirect_to target, allow_other_host: true
      else
        render plain: "Authentication required", status: :unauthorized
      end
    end

    # What the host's login flow returns the visitor to. The activation
    # screen overrides this to drop its query string: the prefill link
    # carries a live user code, and the session store must not keep one.
    def return_to_after_authenticating_url
      request.url
    end
  end
end
