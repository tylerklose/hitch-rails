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
    # An hour. Past this the window stops being "the response was lost" and
    # starts being a second life for a spent credential.
    MAX_REPLAY_GRACE_SECONDS = 3_600
    MAX_SCOPES = 32
    MAX_SCOPE_BYTES = 64
    MAX_SCOPE_SET_BYTES = 255

    # The shipped consent-screen label table (see client_names).
    DEFAULT_CLIENT_NAMES = {
      "claude.ai" => "Claude",
      /\A([\w-]+\.)?chatgpt\.com\z/ => "ChatGPT",
      /\A([\w-]+\.)?openai\.com\z/ => "ChatGPT",
      /\A([\w-]+\.)?cursor\.(com|sh)\z/ => "Cursor",
      /\A([\w-]+\.)?windsurf\.com\z/ => "Windsurf",
      /\A([\w-]+\.)?gemini\.google\.com\z/ => "Gemini",
      "grok.com" => "Grok",
      /\A([\w-]+\.)?x\.ai\z/ => "Grok",
      "localhost" => "Local Development",
      "127.0.0.1" => "Local Development"
    }.freeze

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

    # Consent-screen labels for known client hosts, matched against the
    # VERIFIED redirect_uri host — never the client's declared name, which
    # is attacker-controllable in both registration schemes. Entries match
    # in order with case/when semantics: a String key is an exact host, a
    # Regexp key matches the host; first match wins, and an unmatched host
    # is displayed as itself. Assign a whole Hash to customize (extend the
    # default with `Hitch::Configuration::DEFAULT_CLIENT_NAMES.merge(...)`).
    # @return [Hash{String,Regexp => String}]
    attr_reader :client_names

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

    # Issue a refresh token alongside each access token, and accept
    # grant_type=refresh_token at the token endpoint. Default true.
    #
    # The one setting in this file whose library fallback is ON. An access
    # token lives an hour; without a refresh token a hosted client's only
    # renewal is the full consent redirect, so a flag nobody flips leaves
    # every adopter's connector asking the same human the same question every
    # hour. The flag exists to let an adopter close the surface deliberately,
    # not to decide whether the feature does its job.
    # @return [Boolean]
    attr_reader :refresh_tokens_enabled

    # Idle window for one refresh token, in seconds. Default 2_592_000
    # (30 days). Each rotation issues a successor with a fresh window, so a
    # connector in regular use never reaches it and an abandoned one goes
    # quiet on its own.
    # @return [Integer]
    attr_reader :refresh_token_lifetime_seconds

    # Optional absolute ceiling on a refresh-token family, in seconds,
    # counted from the authorization the family descends from and never
    # extended by rotation. Default nil: no ceiling.
    #
    # A ceiling disconnects a person who has done nothing wrong. It does not
    # reset, so someone using the app every day is cut off the moment it
    # passes and made to consent again — which is the interruption this
    # feature exists to remove, arriving on a timer instead of hourly. The
    # idle window already retires what nobody is using.
    #
    # What a ceiling would still buy, for an operator who wants one: rotation
    # and reuse detection catch a thief the moment the real client refreshes
    # again, because the replay collides. They cannot catch a theft where the
    # real client never comes back, so nothing ever collides. A ceiling ends
    # that case on a clock; without one it ends at revocation.
    # @return [Integer, nil]
    attr_reader :refresh_token_family_lifetime_seconds

    # How long after a refresh token is consumed a repeat presentation is
    # read as an honest retry rather than a replay, in seconds. Default 60.
    # Set 0 for strict one-time-use.
    #
    # A token request is a POST whose response can be lost — a sleeping
    # laptop, a network handoff, a server restarting between commit and
    # response. Without this window the client's retry is indistinguishable
    # from a thief's replay, so a dropped packet revokes the family and logs
    # a real user out with a theft alarm. Within it, the retry rotates again
    # and returns a fresh pair.
    # @return [Integer]
    attr_reader :refresh_token_replay_grace_seconds

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

    # Same boot-time shape as mcp.validate_rate_limit_store!, and for the same
    # reason: the engine's initializer must not resolve the default store by
    # way of ActionController::Base while the application is initializing.
    def validate_dynamic_client_registration_rate_store!
      Hitch::RateLimitStore.assert_shared_at_boot!(
        @dynamic_client_registration_rate_store,
        setting: Hitch::DynamicRegistrationRateLimit::SETTING
      )
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
      @client_names = DEFAULT_CLIENT_NAMES
      @supported_scopes = [ "mcp".freeze ].freeze
      @access_token_lifetime_seconds = 3600
      @authorization_code_lifetime_seconds = 600
      @refresh_tokens_enabled = true
      @refresh_token_lifetime_seconds = 30 * 86_400
      @refresh_token_family_lifetime_seconds = nil
      @refresh_token_replay_grace_seconds = 60
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

    def client_names=(value)
      valid = value.is_a?(Hash) && value.all? do |matcher, label|
        (matcher.is_a?(String) || matcher.is_a?(Regexp)) && label.is_a?(String)
      end
      unless valid
        raise ArgumentError,
          "client_names must be a Hash of String or Regexp host matchers to String labels"
      end

      @client_names = value.to_h do |matcher, label|
        [ matcher.is_a?(String) ? matcher.dup.freeze : matcher, label.dup.freeze ]
      end.freeze
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

    def refresh_tokens_enabled=(value)
      unless value == true || value == false
        raise ArgumentError, "refresh_tokens_enabled must be true or false"
      end

      @refresh_tokens_enabled = value
    end

    def refresh_token_lifetime_seconds=(value)
      @refresh_token_lifetime_seconds =
        positive_lifetime_setting(value, "refresh_token_lifetime_seconds")
    end

    def refresh_token_family_lifetime_seconds=(value)
      @refresh_token_family_lifetime_seconds = if value.nil?
        nil
      else
        positive_lifetime_setting(value, "refresh_token_family_lifetime_seconds")
      end
    end

    def refresh_token_replay_grace_seconds=(value)
      seconds = integer_setting(value, "refresh_token_replay_grace_seconds")
      # Zero is strict one-time-use, which is a posture rather than a mistake.
      unless seconds >= 0 && seconds <= MAX_REPLAY_GRACE_SECONDS
        raise ArgumentError,
          "refresh_token_replay_grace_seconds must be 0 to #{MAX_REPLAY_GRACE_SECONDS}"
      end

      @refresh_token_replay_grace_seconds = seconds
    end

    def dynamic_client_registration_limit=(value)
      unless value.respond_to?(:to_h)
        raise ArgumentError, "dynamic_client_registration_limit must contain :to and :within"
      end

      limit = value.to_h.transform_keys(&:to_sym)
      unless limit.keys.sort == %i[to within]
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
      Rails.env.local?
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

      canonical = uri.dup
      canonical.hostname = uri.hostname.downcase
      origin == Hitch::ResourceUri.origin(canonical)
    rescue URI::InvalidURIError
      false
    end

    # A lifetime past AccessToken::MAX_LIFETIME_SECONDS overflows a Postgres
    # timestamp and sorts before today on SQLite, which would hand an operator
    # a credential that silently never resolves.
    def positive_lifetime_setting(value, name)
      seconds = integer_setting(value, name)
      return seconds if seconds.positive? && seconds <= Hitch::AccessToken::MAX_LIFETIME_SECONDS

      raise ArgumentError,
        "#{name} must be a positive number of seconds, at most " \
          "#{Hitch::AccessToken::MAX_LIFETIME_SECONDS}"
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
