# frozen_string_literal: true

require "json"
require "rack/mock"
require "securerandom"
require "uri"

module Hitch
  class Doctor
    SCHEMA = "hitch.doctor.v1"
    CHECK_IDS = %w[
      versions
      configuration
      resource_discovery
      route_order
      migrations
      registry
      hosts
      origins
      rate_limit_store
    ].freeze
    # What to do about it, keyed by the code that named it. A diagnosis
    # without a next step sends the reader back to the source, which is the
    # thing a doctor exists to save them from. Machine consumers get the
    # same answer from `details` plus this file.
    REMEDIES = {
      "unsupported" => "Match Hitch's supported window, or upgrade Hitch.",
      "invalid" => "Run the failing setting's validation directly: Hitch.configuration.validate!",
      "unresolvable" => "Fix the tool class named by the boot error; " \
        "Hitch.configuration.validate! does not build the registry and will report success.",
      "mismatch" => "resource_uri must equal the URI clients send as `resource`, byte for byte.",
      "missing_endpoint" => "Add `match \"/mcp\", to: \"mcp#handle\", via: :all` to config/routes.rb.",
      "invalid_engine_mount" => "Mount the engine exactly once, at root: `mount Hitch::Engine => \"/\"`.",
      "wrong_verbs" => "The MCP route needs `via: :all` — the endpoint answers POST and OPTIONS.",
      "shadowed" => "Move the MCP route above whichever host route matches the same path first.",
      "after_engine" => "Put the MCP route before `mount Hitch::Engine`.",
      "missing" => "Run bin/rails db:migrate.",
      "empty" => "Register a tool: bin/rails generate hitch:tool NAME.",
      "blocked" => "Add the host to config.hosts, or remove it from Hitch's allowed_hosts.",
      "insecure_http" => "Use https origins in production; plain http ones cannot be trusted.",
      "uncountable" => "Point mcp.rate_limit_store at a store whose #increment returns a count.",
      "unshared" => "Configure a shared config.cache_store (Solid Cache, Redis, Memcached), " \
        "or set mcp.rate_limit_store explicitly.",
      "probe_error" => "The check itself could not run; HITCH_DOCTOR_FORMAT=json names the error class."
    }.freeze
    Check = Data.define(:id, :status, :code, :summary, :details) do
      def initialize(id:, status:, code:, summary:, details: {})
        super(
          id: id.to_s.freeze,
          status: status.to_s.freeze,
          code: code.to_s.freeze,
          summary: summary.to_s.freeze,
          details: Doctor.copy_json(details)
        )
        freeze
      end

      def to_h
        {
          "id" => id,
          "status" => status,
          "code" => code,
          "summary" => summary,
          "details" => details
        }
      end
    end

    Report = Data.define(:schema, :status, :checks) do
      def initialize(schema:, status:, checks:)
        super(schema: schema.to_s.freeze, status: status.to_s.freeze, checks: checks.dup.freeze)
        freeze
      end

      def failure?
        checks.any? { |check| check.status == "fail" }
      end

      def to_h
        {
          "schema" => schema,
          "status" => status,
          "checks" => checks.map(&:to_h)
        }
      end
    end

    class System
      REQUIRED_TABLES = %w[
        hitch_access_tokens
        hitch_clients
        hitch_client_redirect_uris
      ].freeze

      def versions
        {
          "hitch" => Hitch::VERSION,
          "rails" => Rails.version,
          "ruby" => RUBY_VERSION,
          "mcp" => Gem.loaded_specs["mcp"]&.version&.to_s
        }
      end

      def environment_name
        Rails.env.to_s
      end

      def validate_configuration!
        configuration = Hitch.configuration
        configuration.validate!
        if Rails.env.production? && configuration.dynamic_client_registration_enabled
          store = configuration.dynamic_client_registration_rate_store
          Hitch::RateLimitStore.assert_shared!(
            store, setting: Hitch::DynamicRegistrationRateLimit::SETTING
          )
          probe_registration_store!(store)
        end
        true
      end

      # A dedicated-but-unreachable registration store passes the class check
      # while every production registration 503s; drive it like the admission
      # probe does. Registration refuses on an uncountable store, so this
      # mirrors the request path rather than adding a stricter one.
      def probe_registration_store!(store)
        key = "hitch:doctor:v1:#{SecureRandom.hex(16)}"
        count = begin
          store.increment(key, 1, expires_in: 5)
        rescue NotImplementedError
          nil
        end
        return true if count.is_a?(Integer)

        raise Hitch::DynamicRegistrationRateLimit::Unavailable,
          "#{Hitch::DynamicRegistrationRateLimit::SETTING} cannot count registration attempts"
      ensure
        begin
          store&.delete(key)
        # NotImplementedError included: a raise here would replace the
        # Unavailable this method exists to report.
        rescue NotImplementedError, StandardError
          nil
        end
      end

      def runtime_enabled?
        Hitch.configuration.mcp.enabled
      end

      def discovery_facts
        resource = URI.parse(Hitch.configuration.resource_uri.to_s)
        issuer = Hitch::ResourceUri.origin(resource)
        resource_metadata_uri = Hitch::ResourceUri.protected_resource_metadata_url(resource)
        authorization = application_get("/.well-known/oauth-authorization-server", resource)
        protected_resource = application_get(URI.parse(resource_metadata_uri).request_uri, resource)

        {
          "resource_uri" => Hitch.configuration.resource_uri,
          "issuer" => issuer,
          "resource_metadata_uri" => resource_metadata_uri,
          "authorization_status" => authorization.fetch("status"),
          "authorization_document" => authorization.fetch("document"),
          "resource_status" => protected_resource.fetch("status"),
          "resource_document" => protected_resource.fetch("document")
        }
      end

      def route_facts
        resource = URI.parse(Hitch.configuration.resource_uri.to_s)
        resource_path = resource.path
        resource_path = "/" if resource_path.empty?
        routes = Rails.application.routes.routes.to_a
        endpoint_indexes = routes.each_index.select do |index|
          route = routes.fetch(index)
          normalized_route_path(route) == resource_path && modern_endpoint_route?(route)
        end
        engine_indexes = routes.each_index.select { |index| hitch_engine_route?(routes.fetch(index)) }
        endpoint_index = endpoint_indexes.one? ? endpoint_indexes.first : nil
        endpoint_route = routes.fetch(endpoint_index) if endpoint_index
        expected_target = if endpoint_route
          {
            "controller" => endpoint_route.defaults[:controller].to_s,
            "action" => endpoint_route.defaults[:action].to_s
          }
        end
        recognized_targets = ActionDispatch::Request::HTTP_METHODS.to_h do |http_method|
          method = http_method.downcase
          [ method, recognized_route_target(resource.to_s, method) ]
        end
        predecessors = if endpoint_index
          routes.each_index.select do |index|
            index < endpoint_index && normalized_route_path(routes.fetch(index)) == resource_path
          end
        else
          []
        end

        {
          "resource_path" => resource_path,
          "endpoint_indexes" => endpoint_indexes,
          "endpoint_all_verbs" => endpoint_index ? routes.fetch(endpoint_index).verb.to_s.empty? : false,
          "endpoint_reachable" => expected_target && recognized_targets.values.all? { |target| target == expected_target },
          "recognized_targets" => recognized_targets,
          "same_path_predecessor_indexes" => predecessors,
          "engine_mount_indexes" => engine_indexes,
          "engine_mount_paths" => engine_indexes.map { |index| normalized_route_path(routes.fetch(index)) }
        }
      end

      def migration_facts
        connection = ActiveRecord::Base.connection
        installed = ActiveRecord::Base.connection_pool.migration_context.get_all_versions.map(&:to_s)
        required = Dir[Hitch::Engine.root.join("db/migrate/*.rb")].map do |path|
          File.basename(path).split("_", 2).first
        end.sort
        {
          "required_versions" => required,
          "missing_versions" => required - installed,
          "missing_tables" => REQUIRED_TABLES.reject { |table| connection.data_source_exists?(table) }
        }
      end

      def registry_facts
        configuration = Hitch.configuration
        snapshot = Hitch::MCP::Internal::RegistryRuntime.build_snapshot(
          registry_name: configuration.mcp.registry,
          supported_scopes: configuration.supported_scopes
        )
        {
          "registry" => snapshot.registry_name,
          "tool_count" => snapshot.entries.length,
          "tool_names" => snapshot.entries.map(&:name)
        }
      end

      def host_facts
        resource_host = URI.parse(Hitch.configuration.resource_uri.to_s).hostname&.downcase
        configured = Hitch.configuration.allowed_hosts
        expected = [ resource_host, *configured ].compact.uniq
        rails_hosts = Rails.application.config.hosts
        blocked = if rails_hosts.empty?
          []
        else
          permissions = ActionDispatch::HostAuthorization::Permissions.new(rails_hosts)
          expected.reject { |host| permissions.allows?(host) }
        end
        {
          "canonical_host" => resource_host,
          "configured_hosts" => configured,
          "rails_host_policy_entries" => rails_hosts.length,
          "blocked_hosts" => blocked
        }
      end

      def origin_facts
        origins = Hitch.configuration.allowed_origins
        {
          "configured_origins" => origins,
          "deny_default" => origins.empty?,
          "production" => Rails.env.production?,
          "insecure_production_origins" => Rails.env.production? ? origins.grep(/\Ahttp:\/\//) : []
        }
      end

      # Drives the real store rather than describing it: two increments on an
      # isolated key must return 1 then 2, and the key must expire on its own.
      def rate_limit_store_facts
        configuration = Hitch.configuration.mcp
        store = configuration.rate_limit_store
        key = "hitch:doctor:v1:#{SecureRandom.hex(16)}"
        first = store.increment(key, 1, expires_in: 5)
        second = store.increment(key, 1, expires_in: 5)

        {
          "store_class" => store.class.name,
          "counts" => [ first, second ] == [ 1, 2 ],
          # Integers and nil verbatim; anything else only by class, so a
          # broken store cannot put message text into the report.
          "returned" => [ first, second ].map do |value|
            value.is_a?(Integer) || value.nil? ? value : value.class.name
          end,
          "unshared" => Hitch::RateLimitStore.unshared?(store),
          "environment" => environment_name
        }
      ensure
        begin
          store&.delete(key)
        # NotImplementedError included so a store without delete cannot
        # replace this probe's own result mid-ensure.
        rescue NotImplementedError, StandardError
          nil
        end
      end


      private

      def application_get(path, resource)
        environment = Rack::MockRequest.env_for(
          path,
          method: "GET",
          "HTTP_HOST" => Hitch::ResourceUri.authority(resource),
          "SERVER_NAME" => resource.host,
          "SERVER_PORT" => resource.port.to_s,
          "rack.url_scheme" => resource.scheme,
          "HTTPS" => ("on" if resource.scheme == "https")
        ).compact
        status, _headers, body = Rails.application.call(environment)
        bytes = +""
        body.each do |part|
          bytes << part.to_s
          raise "discovery response exceeds diagnostic bound" if bytes.bytesize > 1_048_576
        end
        { "status" => status, "document" => JSON.parse(bytes) }
      ensure
        body&.close if body.respond_to?(:close)
      end

      def normalized_route_path(route)
        route.path.spec.to_s.sub(/\(\.?:format\)\z/, "").sub("(.:format)", "")
      end

      def recognized_route_target(resource_uri, method)
        parameters = Rails.application.routes.recognize_path(resource_uri, method: method.to_sym)
        {
          "controller" => parameters[:controller].to_s,
          "action" => parameters[:action].to_s
        }
      rescue ActionController::RoutingError, AbstractController::ActionNotFound, NameError
        nil
      end

      def modern_endpoint_route?(route)
        route.defaults[:action].to_s == "handle" && controller_uses?(route, Hitch::MCP::Endpoint)
      end

      def controller_uses?(route, concern)
        controller = route.defaults[:controller].to_s
        return false if controller.empty?

        controller_class = "#{controller}_controller".camelize.constantize
        controller_class.ancestors.include?(concern)
      rescue NameError
        false
      end

      def hitch_engine_route?(route)
        application = route.app
        seen = {}
        loop do
          return true if application.equal?(Hitch::Engine)
          return false if seen.key?(application.object_id) || !application.respond_to?(:app)

          seen[application.object_id] = true
          replacement = application.app
          return false if replacement.equal?(application)

          application = replacement
        end
      end
    end

    class << self
      def call(system: System.new)
        new(system:).call
      end

      def render(report, format: "human")
        case format
        when "human" then render_human(report)
        when "json" then "#{JSON.pretty_generate(report.to_h)}\n"
        else raise ArgumentError, "HITCH_DOCTOR_FORMAT must be human or json"
        end
      end

      # Bounds hostile store output: keys and non-JSON values are coerced to
      # strings, so a broken store cannot put rich objects into the report.
      # Cyclic input raises (and the check reports probe_error) instead of
      # recursing without a floor.
      def copy_json(value)
        Hitch::MCP::Internal::JsonValues.copy(
          value, keys: :to_s, symbols: :to_s, foreign: :to_s, freeze: true
        )
      end

      private

      def render_human(report)
        lines = [ "Hitch doctor v1: #{report.status.upcase}" ]
        report.checks.each do |check|
          lines << format("%-4s %-24s %-28s %s", check.status.upcase, check.id, check.code, check.summary)
          lines << "     -> #{REMEDIES.fetch(check.code)}" if REMEDIES.key?(check.code)
        end
        counts = %w[pass warn fail skip].to_h do |status|
          [ status, report.checks.count { |check| check.status == status } ]
        end
        lines << "Summary: pass=#{counts.fetch('pass')} warn=#{counts.fetch('warn')} " \
          "fail=#{counts.fetch('fail')} skip=#{counts.fetch('skip')}"
        "#{lines.join("\n")}\n"
      end
    end

    def initialize(system:)
      @system = system
    end

    def call
      checks = [
        versions_check,
        configuration_check,
        resource_discovery_check,
        route_order_check,
        migrations_check,
        registry_check,
        hosts_check,
        origins_check,
        rate_limit_store_check
      ]
      raise "Hitch doctor check set drifted" unless checks.map(&:id) == CHECK_IDS

      overall = if checks.any? { |check| check.status == "fail" }
        "error"
      elsif checks.any? { |check| check.status == "warn" }
        "warning"
      else
        "ok"
      end
      Report.new(schema: SCHEMA, status: overall, checks:)
    end

    private

    attr_reader :system

    def versions_check
      versions = system.versions
      # The one authority on supported versions is the gemspec itself.
      specification = Gem.loaded_specs.fetch("hitch-rails")
      dependencies = specification.dependencies.to_h { |dependency| [ dependency.name, dependency.requirement ] }
      requirements = {
        "ruby" => specification.required_ruby_version,
        "rails" => dependencies.fetch("rails"),
        "mcp" => dependencies.fetch("mcp")
      }
      unsupported = requirements.filter_map do |name, requirement|
        value = versions[name]
        name unless value && requirement.satisfied_by?(Gem::Version.new(value))
      rescue ArgumentError
        name
      end
      return pass("versions", "supported", "Runtime versions are in Hitch's supported window", versions) if
        unsupported.empty?

      fail_check(
        "versions",
        "unsupported",
        "One or more runtime versions are outside Hitch's supported window",
        versions.merge("unsupported" => unsupported)
      )
    rescue StandardError => error
      probe_failure("versions", error)
    end

    def configuration_check
      runtime = system.runtime_enabled?
      system.validate_configuration!
      code = runtime ? "valid_full_runtime" : "valid_auth_only"
      summary = runtime ? "OAuth and MCP runtime configuration is valid" : "OAuth configuration is valid; MCP runtime is disabled"
      pass("configuration", code, summary, "environment" => system.environment_name, "runtime_enabled" => runtime)
    rescue StandardError => error
      environment = begin
        system.environment_name
      rescue StandardError
        "unavailable"
      end
      fail_check(
        "configuration",
        "invalid",
        "Hitch configuration is invalid",
        "environment" => environment,
        "error_class" => error.class.name
      )
    end

    def resource_discovery_check
      facts = system.discovery_facts
      resource = URI.parse(facts.fetch("resource_uri"))
      issuer = facts.fetch("issuer")
      authorization = facts.fetch("authorization_document")
      protected_resource = facts.fetch("resource_document")
      coherent = facts.fetch("authorization_status") == 200 && facts.fetch("resource_status") == 200 &&
        authorization["issuer"] == issuer &&
        authorization["authorization_endpoint"] == "#{issuer}/oauth/authorize" &&
        authorization["token_endpoint"] == "#{issuer}/oauth/token" &&
        protected_resource["resource"] == facts.fetch("resource_uri") &&
        protected_resource["authorization_servers"] == [ issuer ] &&
        URI.parse(facts.fetch("resource_metadata_uri")).query == resource.query
      details = facts.slice("resource_uri", "issuer", "resource_metadata_uri", "authorization_status", "resource_status")
      return pass("resource_discovery", "coherent", "Canonical resource and discovery documents agree", details) if coherent

      fail_check("resource_discovery", "mismatch", "Canonical resource and discovery documents do not agree", details)
    rescue StandardError => error
      probe_failure("resource_discovery", error)
    end

    def route_order_check
      return skip(
        "route_order",
        "runtime_disabled",
        "Modern MCP route order is not applicable while the runtime is disabled"
      ) unless system.runtime_enabled?

      facts = system.route_facts
      endpoints = facts.fetch("endpoint_indexes")
      mounts = facts.fetch("engine_mount_indexes")
      return fail_check("route_order", "missing_endpoint", "Exactly one modern MCP endpoint route is required", facts) unless
        endpoints.one?
      return fail_check("route_order", "invalid_engine_mount", "Hitch::Engine must be mounted exactly once at root", facts) unless
        mounts.one? && facts.fetch("engine_mount_paths") == [ "/" ]
      return fail_check("route_order", "wrong_verbs", "The modern MCP route must admit the endpoint's full method contract", facts) unless
        facts.fetch("endpoint_all_verbs")
      return fail_check("route_order", "shadowed", "A host route shadows the canonical MCP endpoint", facts) if
        facts.fetch("same_path_predecessor_indexes").any? || !facts.fetch("endpoint_reachable")
      return fail_check("route_order", "after_engine", "The modern MCP route must precede the Hitch engine mount", facts) unless
        endpoints.first < mounts.first

      pass("route_order", "ordered", "The modern MCP endpoint precedes one root engine mount", facts)
    rescue StandardError => error
      probe_failure("route_order", error)
    end

    def migrations_check
      facts = system.migration_facts
      missing = facts.fetch("missing_versions").any? || facts.fetch("missing_tables").any?
      return fail_check("migrations", "missing", "Required Hitch migrations or tables are missing", facts) if missing

      pass("migrations", "current", "Hitch migrations are current", facts)
    rescue StandardError => error
      probe_failure("migrations", error)
    end

    def registry_check
      return skip("registry", "runtime_disabled", "MCP registry is not applicable while the runtime is disabled") unless
        system.runtime_enabled?

      facts = system.registry_facts
      return warning("registry", "empty", "Registry is valid but exposes no tools", facts) if facts.fetch("tool_count").zero?

      pass("registry", "valid", "Registry is valid and explicitly populated", facts)
    rescue StandardError => error
      fail_check("registry", "unresolvable", "Registry validation failed", "error_class" => error.class.name)
    end

    def hosts_check
      facts = system.host_facts
      return fail_check("hosts", "blocked", "Rails host authorization blocks a configured Hitch host", facts) if
        facts.fetch("blocked_hosts").any?

      pass("hosts", "accepted", "Canonical and configured Hitch hosts pass Rails host authorization", facts)
    rescue StandardError => error
      probe_failure("hosts", error)
    end

    def origins_check
      facts = system.origin_facts
      return warning(
        "origins",
        "insecure_http",
        "Production browser origins include plain HTTP",
        facts
      ) if facts.fetch("insecure_production_origins").any?
      if facts.fetch("deny_default")
        return pass("origins", "deny_default", "Browser CORS remains deny-default", facts)
      end

      pass("origins", "exact", "Browser CORS uses exact configured origins", facts)
    rescue StandardError => error
      probe_failure("origins", error)
    end

    def rate_limit_store_check
      return skip(
        "rate_limit_store",
        "runtime_disabled",
        "Request admission is not applicable while the MCP runtime is disabled"
      ) unless system.runtime_enabled?

      facts = system.rate_limit_store_facts
      # The code names the defect; the status says how much it matters. Only
      # production refuses, matching the runtime.
      report = system.environment_name == "production" ? method(:fail_check) : method(:warning)

      return report.call(
        "rate_limit_store",
        "uncountable",
        "The configured store cannot count MCP requests",
        facts
      ) unless facts.fetch("counts")

      return report.call(
        "rate_limit_store",
        "unshared",
        "The configured store cannot count one principal's requests across processes",
        facts
      ) if facts.fetch("unshared")

      pass(
        "rate_limit_store",
        "shared",
        "Request admission counts through a store shared across processes",
        facts
      )
    # NotImplementedError (a ScriptError): the base Store#increment raises it
    # when a store never overrode increment; the report must survive that.
    rescue NotImplementedError, StandardError => error
      probe_failure("rate_limit_store", error)
    end

    def pass(id, code, summary, details = {})
      Check.new(id:, status: "pass", code:, summary:, details:)
    end

    def warning(id, code, summary, details = {})
      Check.new(id:, status: "warn", code:, summary:, details:)
    end

    def fail_check(id, code, summary, details = {})
      Check.new(id:, status: "fail", code:, summary:, details:)
    end

    def skip(id, code, summary, details = {})
      Check.new(id:, status: "skip", code:, summary:, details:)
    end

    def probe_failure(id, error)
      fail_check(id, "probe_error", "The #{id.tr('_', ' ')} diagnostic could not complete", "error_class" => error.class.name)
    end

    private_constant :Check, :Report, :System
  end
end
