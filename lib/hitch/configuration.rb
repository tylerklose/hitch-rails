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

    # Accept an https URL as a client_id and fetch client metadata from
    # it (Client ID Metadata Documents, the successor to Dynamic Client
    # Registration in MCP 2026-07-28).
    #
    # The library fallback is false, so upgrading an existing application
    # changes nothing. The GENERATED INITIALIZER sets it to true, so new
    # installations are conformant through configuration they own and can
    # see — MCP 2026-07-28 makes supporting CIMD a SHOULD and demotes
    # Dynamic Client Registration to a deprecated MAY, and clients read
    # `client_id_metadata_document_supported` to choose between them.
    #
    # The split is by installation cohort rather than by runtime
    # condition because the prerequisite cannot be inferred: CIMD needs
    # this app to reach arbitrary https hosts on 443 DIRECTLY, and
    # build_connection deliberately ignores http_proxy (honouring it
    # would reach the destination from the proxy's egress rather than
    # this app's). A host behind a proxy that flipped this on would begin
    # ADVERTISING support it cannot deliver, steering conformant clients
    # off a working path onto a broken one, invisibly until a client
    # tries.
    #
    # `bin/rails 'hitch:cimd:check[URL]'` exercises the real fetch path
    # against a document the operator trusts, and works whether or not
    # this is enabled. Once an upgrade cycle has passed, this fallback
    # can flip in a breaking release.
    # @return [Boolean]
    attr_accessor :client_id_metadata_enabled

    # How long a successfully resolved client metadata document is
    # cached. Default 3600 (1 hour). Longer means fewer outbound
    # fetches; shorter means a client's redirect_uri changes take effect
    # sooner.
    # @return [Integer]
    attr_accessor :client_id_metadata_cache_ttl

    # Ceiling on client metadata fetches in flight AT ONCE, per process.
    # Default 4. Set to nil to disable; 0 blocks every fetch.
    #
    # Each fetch can occupy a request thread for the whole resolution
    # budget, so without a cap enough slow ones saturate the pool and the
    # app stops serving anything. This bounds CIMD to a slice of the
    # thread pool no matter what callers do: a Puma worker running the
    # default 5 threads keeps one free. It is per process, so a fleet
    # ceiling is this times the worker count.
    # @return [Integer]
    attr_accessor :client_id_metadata_max_concurrent_fetches

    # Ceiling on client metadata fetches per signed-in principal per
    # minute. Default 20. Set to nil to disable.
    #
    # The concurrency cap above protects THIS server; this one protects
    # everyone else. Negative caching cannot: an attacker with a wildcard
    # DNS record gets unlimited distinct hosts, and a host that answers
    # with 404s gets one fetch per distinct URL. Neither trick changes
    # who is asking, so counting per principal is what actually bounds
    # the volume of traffic this server can be aimed at a third party.
    #
    # Counted in process, under a mutex, rather than in Rails.cache: the
    # check and the increment have to be one operation, and doing them as
    # a cache read plus a cache write lets every caller the concurrency
    # cap admits read the same value and write value+1 — the limit
    # multiplied by the cap rather than approached. So this bound is per
    # process, and a fleet ceiling is this times the worker count. It is
    # unaffected by the cache store.
    # @return [Integer, nil]
    attr_accessor :client_id_metadata_fetches_per_minute

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
      @client_id_metadata_enabled = false
      @client_id_metadata_cache_ttl = 3600
      @client_id_metadata_max_concurrent_fetches = 4
      @client_id_metadata_fetches_per_minute = 20
    end

    # Resolve principal_model to its class constant.
    # @return [Class] the principal AR model class
    def principal_class
      principal_model.is_a?(String) ? principal_model.constantize : principal_model
    end
  end
end
