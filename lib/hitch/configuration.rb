# frozen_string_literal: true

require "uri"

module Hitch
  # Host-app configuration. Configure via Hitch.configure { |c| ... }
  # in an initializer.
  #
  # The load-bearing knob is resource_uri: this MCP server's canonical URI for
  #   RFC 8707 audience binding. MUST match the URI clients use when
  #   requesting tokens with the `resource` parameter. Required for
  #   spec conformance.
  class Configuration
    MAX_RESOURCE_URI_BYTES = 2_048
    MAX_SCOPES = 32
    MAX_SCOPE_BYTES = 64
    MAX_SCOPE_SET_BYTES = 255

    # @return [String] e.g. "https://example.com/mcp"
    attr_reader :resource_uri

    # Additional exact request hosts accepted by Hitch's engine endpoints.
    # The host component of resource_uri is always accepted as canonical.
    # Values are hostnames or IP literals only: no scheme, port, or path.
    # @return [Array<String>]
    attr_reader :allowed_hosts

    # Exact browser origins that may read Hitch responses. Development and
    # test also accept loopback origins; production never infers an origin.
    # @return [Array<String>]
    attr_reader :allowed_origins

    # Brand display name shown on the consent screen.
    # @return [String]
    attr_accessor :brand_name

    # OAuth scopes the host app supports. The first entry is the base/default
    # scope requested by the generic MCP bearer challenge; later entries are
    # available for tool-specific 403 step-up. Default: ["mcp"].
    # @return [Array<String>]
    attr_reader :supported_scopes

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
    # installations adopt the profile's preferred registration posture through
    # configuration they own and can see — MCP 2026-07-28 makes supporting CIMD
    # a SHOULD and demotes
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

    # Whether POST /oauth/register is available. The library fallback is true
    # to preserve the unreleased upgrade path; the install generator writes an
    # explicit false for new applications.
    # @return [Boolean]
    attr_reader :dynamic_client_registration_enabled

    # Fixed-window DCR quota. `to` is the maximum number of attempts and
    # `within` is the expiry window in seconds (or an ActiveSupport duration).
    # @return [Hash{Symbol => Integer}]
    attr_reader :dynamic_client_registration_limit

    # Any ActiveSupport::Cache store responding to increment. Nil counts
    # through config.action_controller.cache_store, like every other Rails
    # rate limit.
    # @return [ActiveSupport::Cache::Store, nil]
    def dynamic_client_registration_rate_store
      Hitch::RateLimitStore.resolve(@dynamic_client_registration_rate_store)
    end

    def dynamic_client_registration_rate_store=(value)
      @dynamic_client_registration_rate_store = Hitch::RateLimitStore.validate!(
        value, setting: "config.dynamic_client_registration_rate_store"
      )
    end

    # MCP transport and tool configuration. This remains a separate value so
    # the OAuth surface and MCP runtime can validate their own settings without
    # introducing a second top-level configuration authority.
    # @return [Hitch::MCP::Configuration]
    attr_reader :mcp

    def initialize
      @resource_uri = nil
      @allowed_hosts = [].freeze
      @allowed_origins = [].freeze
      @brand_name = "Rails MCP"
      @supported_scopes = [ "mcp".freeze ].freeze
      @access_token_lifetime_seconds = 3600
      @authorization_code_lifetime_seconds = 600
      @principal_method = :current_user
      @login_path = nil
      @client_id_metadata_enabled = false
      @client_id_metadata_cache_ttl = 3600
      @client_id_metadata_max_concurrent_fetches = 4
      @client_id_metadata_fetches_per_minute = 20
      @dynamic_client_registration_enabled = true
      @dynamic_client_registration_enabled_configured = false
      @dynamic_client_registration_limit = { to: 20, within: 60 }.freeze
      @dynamic_client_registration_rate_store = nil
      @mcp = Hitch::MCP::Configuration.new
    end

    def allowed_hosts=(values)
      @allowed_hosts = validate_hosts(values).freeze
    end

    def resource_uri=(value)
      @resource_uri = if value.nil?
        nil
      else
        canonical = Hitch::ResourceUri.canonicalize!(
          value,
          allow_loopback_http: loopback_resource_uri_allowed?
        )
        if canonical.bytesize > MAX_RESOURCE_URI_BYTES
          raise Hitch::ResourceUri::Invalid,
            "resource must not exceed #{MAX_RESOURCE_URI_BYTES} bytes"
        end

        canonical.dup.freeze
      end
    end

    def allowed_origins=(values)
      @allowed_origins = validate_origins(values).freeze
    end

    def supported_scopes=(values)
      unless values.is_a?(Array)
        raise ArgumentError, "supported_scopes must be an array of OAuth scope tokens"
      end

      scopes = values.map do |value|
        scope = value.is_a?(String) ? value.dup : nil
        unless scope&.match?(/\A[\x21\x23-\x5B\x5D-\x7E]+\z/) && scope.bytesize <= MAX_SCOPE_BYTES
          raise ArgumentError, "supported_scopes entries must be valid OAuth scope tokens"
        end

        scope.freeze
      end
      raise ArgumentError, "supported_scopes must not be empty" if scopes.empty?
      if scopes.length > MAX_SCOPES
        raise ArgumentError, "supported_scopes must not contain more than #{MAX_SCOPES} entries"
      end
      raise ArgumentError, "supported_scopes must not contain duplicates" unless scopes.uniq.length == scopes.length
      if scopes.join(" ").bytesize > MAX_SCOPE_SET_BYTES
        raise ArgumentError, "supported_scopes exceed the #{MAX_SCOPE_SET_BYTES}-byte persisted scope boundary"
      end

      @supported_scopes = scopes.freeze
    end

    def dynamic_client_registration_enabled=(value)
      unless value == true || value == false
        raise ArgumentError, "dynamic_client_registration_enabled must be true or false"
      end

      @dynamic_client_registration_enabled_configured = true
      @dynamic_client_registration_enabled = value
    end

    def dynamic_client_registration_enabled_configured?
      @dynamic_client_registration_enabled_configured
    end

    def validate!
      if resource_uri.present?
        mcp.validate!
        return true
      end

      raise ArgumentError,
        "Hitch.configuration.resource_uri is required; set it to the canonical MCP endpoint URI"
    end

    def dynamic_client_registration_limit=(value)
      unless value.respond_to?(:to_h)
        raise ArgumentError, "dynamic_client_registration_limit must contain :to and :within"
      end

      limit = value.to_h.transform_keys(&:to_sym)
      unknown_keys = limit.keys - %i[to within]
      unless unknown_keys.empty? && limit.keys.sort == %i[to within].sort
        raise ArgumentError, "dynamic_client_registration_limit must contain only :to and :within"
      end

      to = integer_setting(limit[:to], "dynamic_client_registration_limit[:to]")
      within = integer_setting(limit[:within], "dynamic_client_registration_limit[:within]")
      raise ArgumentError, "dynamic_client_registration_limit[:to] must be positive" unless to.positive?
      raise ArgumentError, "dynamic_client_registration_limit[:within] must be positive" unless within.positive?

      @dynamic_client_registration_limit = { to: to, within: within }.freeze
    end

    private

    def loopback_resource_uri_allowed?
      Rails.env.development? || Rails.env.test?
    end

    def validate_hosts(values)
      unless values.is_a?(Array)
        raise ArgumentError, "allowed_hosts must be an array of exact hostnames or IP literals"
      end

      values.map do |value|
        host = value.is_a?(String) ? value.strip.downcase : nil
        unless valid_host_literal?(host)
          raise ArgumentError, "allowed_hosts entries must be hostnames or IP literals without scheme, port, or path"
        end
        host.dup.freeze
      end.uniq
    end

    def validate_origins(values)
      unless values.is_a?(Array)
        raise ArgumentError, "allowed_origins must be an array of exact http(s) origins"
      end

      values.map do |value|
        origin = value.is_a?(String) ? value.strip : nil
        unless valid_origin?(origin)
          raise ArgumentError, "allowed_origins entries must be canonical http(s) origins without path, query, or fragment"
        end

        origin.dup.freeze
      end.uniq
    end

    def valid_host_literal?(host)
      return false if host.blank? || host.end_with?(".")
      return true if host.match?(/\A[0-9a-f:]+\z/i) && host.include?(":")

      labels = host.split(".")
      labels.all? do |label|
        label.length.between?(1, 63) && label.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/i)
      end
    end

    def valid_origin?(origin)
      return false if origin.blank?

      uri = URI.parse(origin)
      return false unless %w[http https].include?(uri.scheme)
      return false if uri.hostname.blank? || uri.userinfo || uri.query || uri.fragment
      return false unless uri.path.blank?

      default_port = uri.scheme == "https" ? 443 : 80
      hostname = uri.hostname.downcase
      authority_host = hostname.include?(":") ? "[#{hostname}]" : hostname
      canonical = "#{uri.scheme}://#{authority_host}"
      canonical += ":#{uri.port}" unless uri.port == default_port
      origin == canonical
    rescue URI::InvalidURIError
      false
    end

    def integer_setting(value, name)
      integer = if value.is_a?(Integer)
        value
      elsif value.respond_to?(:to_i) && !value.is_a?(Float)
        parsed = value.to_i
        parsed if parsed.to_s == value.to_s
      end

      integer || raise(ArgumentError, "#{name} must be an integer number of seconds")
    end
  end
end
