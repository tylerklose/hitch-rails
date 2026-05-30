# frozen_string_literal: true

module Hitch
  # Host-app configuration. Configure via Hitch.configure { |c| ... }
  # in an initializer.
  #
  # The two load-bearing knobs:
  # - principal_model: which AR model represents the OAuth principal.
  #   Default "User". Host apps with a different identity model (Account,
  #   a team-scoped user, etc.) override this. The model is expected to
  #   respond to #id and an identifier such as #email_address, plus
  #   whatever scoping the host app's MCP tools need.
  # - resource_uri: this MCP server's canonical resource URI for
  #   RFC 8707 audience binding. MUST match the URI clients use when
  #   requesting tokens with the `resource` parameter. Required for
  #   spec conformance.
  class Configuration
    # Which AR model is the OAuth principal (resource owner).
    # @return [String] class name; resolved via constantize at use site.
    attr_accessor :principal_model

    # @return [String] e.g. "https://example.com/mcp"
    attr_accessor :resource_uri

    # Brand display name shown on the consent screen.
    # @return [String]
    attr_accessor :brand_name

    # OAuth scopes the host app supports. Default: ["mcp"].
    # @return [Array<String>]
    attr_accessor :supported_scopes

    # Where to redirect after a successful sign-in (the host app's
    # post-login page). Used when the OAuth dance starts unauthenticated.
    # @return [String, nil]
    attr_accessor :post_login_redirect

    # Controller method name that returns the current authenticated
    # principal. Default :current_user — most Rails apps already define
    # this. Host apps with custom session schemes (Devise's
    # current_account, etc.) override.
    # @return [Symbol]
    attr_accessor :principal_method

    # Where to redirect when the consent screen is hit by an
    # unauthenticated visitor. String path/URL or callable that takes the
    # request and returns one. If nil, /oauth/authorize returns 401
    # instead of redirecting.
    # @return [String, Proc, nil]
    attr_accessor :login_path

    # Token lifetime in seconds. Default 3600 (1 hour).
    # @return [Integer]
    attr_accessor :access_token_lifetime_seconds

    # Authorization code lifetime in seconds. Default 600 (10 minutes).
    # @return [Integer]
    attr_accessor :authorization_code_lifetime_seconds

    def initialize
      @principal_model = "User"
      @resource_uri = nil
      @brand_name = "Rails MCP"
      @supported_scopes = [ "mcp" ]
      @post_login_redirect = nil
      @access_token_lifetime_seconds = 3600
      @authorization_code_lifetime_seconds = 600
      @principal_method = :current_user
      @login_path = nil
    end

    # Resolve principal_model to its class constant.
    # @return [Class] the principal AR model class
    def principal_class
      principal_model.is_a?(String) ? principal_model.constantize : principal_model
    end
  end
end
