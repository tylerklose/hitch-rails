# frozen_string_literal: true

require "test_helper"
require "hitch/doctor"
require "fileutils"
require "json"
require "set"
require "tmpdir"

class Hitch::DoctorTest < ActiveSupport::TestCase
  Doctor = Hitch::Doctor
  SCENARIO_PATH = Rails.root.join("../lattice/doctor_scenarios.json").expand_path
  SCENARIOS = JSON.parse(SCENARIO_PATH.read).fetch("scenarios").freeze
  HEALTHY_FULL = {
    "runtime" => "full",
    "environment" => "production",
    "configuration" => "valid",
    "discovery" => "coherent",
    "route" => "ordered",
    "migrations" => "current",
    "registry" => "populated",
    "hosts" => "accepted",
    "origins" => "exact",
    "rate_limit_store" => "shared"
  }.freeze
  HEALTHY_AUTH_ONLY = {
    "runtime" => "auth_only",
    "environment" => "test",
    "configuration" => "valid",
    "discovery" => "coherent",
    "route" => "missing",
    "migrations" => "current",
    "registry" => "invalid",
    "hosts" => "accepted",
    "origins" => "deny_default",
    "rate_limit_store" => "unshared"
  }.freeze

  class FixtureSystem
    attr_reader :rate_limit_store_probe_calls

    def initialize(values)
      @values = values
      @rate_limit_store_probe_calls = 0
    end

    def versions
      { "hitch" => "0.2.0.pre.4", "rails" => "8.1.3", "ruby" => "3.4.7", "mcp" => "1.2.0" }
    end

    def environment_name
      values.fetch("environment")
    end

    def validate_configuration!
      raise ArgumentError, "configuration credential-secret" if values.fetch("configuration") == "invalid"

      true
    end

    def runtime_enabled?
      values.fetch("runtime") == "full"
    end

    def discovery_facts
      protected_resource = values.fetch("discovery") == "coherent" ? "https://doctor.example/mcp" :
        "https://wrong.example/mcp"
      {
        "resource_uri" => "https://doctor.example/mcp",
        "issuer" => "https://doctor.example",
        "resource_metadata_uri" => "https://doctor.example/.well-known/oauth-protected-resource/mcp",
        "authorization_status" => 200,
        "authorization_document" => {
          "issuer" => "https://doctor.example",
          "authorization_endpoint" => "https://doctor.example/oauth/authorize",
          "token_endpoint" => "https://doctor.example/oauth/token"
        },
        "resource_status" => 200,
        "resource_document" => {
          "resource" => protected_resource,
          "authorization_servers" => [ "https://doctor.example" ]
        }
      }
    end

    def route_facts
      facts = {
        "resource_path" => "/mcp",
        "endpoint_indexes" => [ 2 ],
        "endpoint_all_verbs" => true,
        "endpoint_reachable" => true,
        "recognized_targets" => {
          "post" => { "controller" => "mcp", "action" => "handle" },
          "options" => { "controller" => "mcp", "action" => "handle" }
        },
        "same_path_predecessor_indexes" => [],
        "engine_mount_indexes" => [ 3 ],
        "engine_mount_paths" => [ "/" ]
      }
      case values.fetch("route")
      when "missing" then facts["endpoint_indexes"] = []
      when "shadowed"
        facts["endpoint_reachable"] = false
        facts["recognized_targets"]["post"] = { "controller" => "host_forms", "action" => "create" }
        facts["same_path_predecessor_indexes"] = [ 1 ]
      when "after_engine"
        facts["endpoint_indexes"] = [ 3 ]
        facts["engine_mount_indexes"] = [ 2 ]
      when "wrong_verbs" then facts["endpoint_all_verbs"] = false
      when "invalid_mount" then facts["engine_mount_paths"] = [ "/auth" ]
      end
      facts
    end

    def migration_facts
      facts = {
        "required_versions" => [ "20260817000000" ],
        "missing_versions" => [],
        "missing_tables" => []
      }
      if values.fetch("migrations") == "missing"
        facts["missing_versions"] = [ "20260817000000" ]
        facts["missing_tables"] = [ "hitch_clients" ]
      end
      facts
    end

    def registry_facts
      raise ArgumentError, "registry internal-secret" if values.fetch("registry") == "invalid"

      names = values.fetch("registry") == "empty" ? [] : [ "weather.lookup" ]
      { "registry" => "McpToolRegistry", "tool_count" => names.length, "tool_names" => names }
    end

    def host_facts
      blocked = values.fetch("hosts") == "blocked" ? [ "doctor.example" ] : []
      {
        "canonical_host" => "doctor.example",
        "configured_hosts" => [],
        "rails_host_policy_entries" => 1,
        "blocked_hosts" => blocked
      }
    end

    def origin_facts
      origins = case values.fetch("origins")
      when "deny_default" then []
      when "exact" then [ "https://client.example" ]
      when "http" then [ "http://client.example" ]
      end
      production = environment_name == "production"
      {
        "configured_origins" => origins,
        "deny_default" => origins.empty?,
        "production" => production,
        "insecure_production_origins" => production ? origins.grep(/\Ahttp:\/\//) : []
      }
    end

    def rate_limit_store_facts
      @rate_limit_store_probe_calls += 1
      raise RuntimeError, "redis://:redis-super-secret@redis.internal:6379/15" if
        values.fetch("rate_limit_store") == "error"

      unshared = values.fetch("rate_limit_store") != "shared"
      counts = values.fetch("rate_limit_store") != "uncountable"
      {
        "store_class" => unshared ? "ActiveSupport::Cache::MemoryStore" : "SolidCache::Store",
        "counts" => counts,
        "returned" => counts ? [ 1, 2 ] : [ nil, nil ],
        "unshared" => unshared,
        "environment" => environment_name
      }
    end

    private

    attr_reader :values
  end

  test "Lattice fixtures exercise all stable categories and actionable outcomes" do
    assert_equal 27, SCENARIOS.length
    assert_equal (1..27).to_a, SCENARIOS.map { |scenario| scenario.fetch("id") }
    seen = Set.new

    SCENARIOS.each do |scenario|
      system = FixtureSystem.new(scenario.fetch("values"))
      report = Doctor.call(system:)
      assert_equal Doctor::CHECK_IDS, report.checks.map(&:id), scenario_label(scenario)
      assert_equal report.checks.any? { |check| check.status == "fail" }, report.failure?, scenario_label(scenario)
      assert_equal expected_overall(report), report.status, scenario_label(scenario)
      report.checks.each { |check| seen << [ check.id, check.status, check.code ] }
      assert_operator system.rate_limit_store_probe_calls, :<=, 1, scenario_label(scenario)

      rendered = Doctor.render(report, format: "json")
      refute_includes rendered, "redis-super-secret", scenario_label(scenario)
      refute_includes rendered, "credential-secret", scenario_label(scenario)
      refute_includes rendered, "internal-secret", scenario_label(scenario)
    end

    expected_outcomes.each { |outcome| assert_includes seen, outcome }

    # Every way the doctor can say something is wrong must also say what to
    # do about it. New failure codes arrive here before they reach a host.
    actionable = seen.reject { |(_id, status, _code)| %w[pass skip].include?(status) }
    missing = actionable.map(&:last).uniq - Doctor::REMEDIES.keys
    assert_empty missing, "doctor codes with no remedy: #{missing.join(', ')}"
  end

  test "human rendering prescribes for what fails and stays quiet for what passes" do
    failing = SCENARIOS.find do |scenario|
      Doctor.call(system: FixtureSystem.new(scenario.fetch("values"))).failure?
    end
    report = Doctor.call(system: FixtureSystem.new(failing.fetch("values")))

    human = Doctor.render(report, format: "human")

    report.checks.each do |check|
      remedy = Doctor::REMEDIES[check.code]
      if %w[pass skip].include?(check.status)
        refute_includes human, "     -> #{remedy}" if remedy
      else
        assert_includes human, "     -> #{remedy}"
      end
    end
    refute_includes Doctor.render(
      Doctor.call(system: FixtureSystem.new(HEALTHY_FULL)), format: "human"
    ), "->"
  end

  test "healthy full runtime and auth-only modes have exact skip semantics" do
    full_report = Doctor.call(system: FixtureSystem.new(HEALTHY_FULL))
    assert_equal "ok", full_report.status
    assert_equal false, full_report.failure?
    assert_equal "shared",
      full_report.checks.find { |check| check.id == "rate_limit_store" }.code

    auth_report = Doctor.call(system: FixtureSystem.new(HEALTHY_AUTH_ONLY))
    assert_equal "ok", auth_report.status
    skipped_codes = %w[route_order registry rate_limit_store].map do |id|
      auth_report.checks.find { |check| check.id == id }.code
    end
    assert_equal Array.new(3, "runtime_disabled"), skipped_codes
  end

  test "human and JSON rendering are deterministic frozen public shapes" do
    report = Doctor.call(system: FixtureSystem.new(HEALTHY_FULL))
    human = Doctor.render(report, format: "human")
    machine = JSON.parse(Doctor.render(report, format: "json"))

    assert_equal "Hitch doctor v1: OK", human.lines.first.chomp
    assert_includes human, "PASS versions"
    assert_includes human, "Summary: pass=9 warn=0 fail=0 skip=0"
    assert_equal [ "schema", "status", "checks" ], machine.keys
    assert_equal "hitch.doctor.v1", machine.fetch("schema")
    assert_equal Doctor::CHECK_IDS, machine.fetch("checks").map { |check| check.fetch("id") }
    assert_predicate report, :frozen?
    assert report.checks.all?(&:frozen?)
    assert report.checks.all? { |check| check.details.frozen? }
    assert_raises(ArgumentError) { Doctor.render(report, format: "yaml") }
  end

  test "unsupported versions and probe exceptions are stable and do not expose messages" do
    system = FixtureSystem.new(HEALTHY_FULL)
    unsupported = -> { { "hitch" => "0.2", "rails" => "9.0", "ruby" => "3.2", "mcp" => nil } }
    failing_discovery = -> { raise RuntimeError, "discovery-bearer-secret" }

    stub_class_method(system, :versions, unsupported) do
      stub_class_method(system, :discovery_facts, failing_discovery) do
        rendered = Doctor.render(Doctor.call(system:), format: "json")
        parsed = JSON.parse(rendered)

        assert_equal "unsupported", parsed.dig("checks", 0, "code")
        assert_equal "probe_error", parsed.dig("checks", 2, "code")
        refute_includes rendered, "discovery-bearer-secret"
      end
    end
  end

  test "real admission-store probe uses an isolated expiring key and always removes it" do
    system = Doctor.const_get(:System, false).new
    calls = []
    store = Class.new(ActiveSupport::Cache::Store) do
      attr_reader :calls

      def initialize(calls)
        super()
        @calls = calls
        @counts = Hash.new(0)
      end

      def increment(name, amount = 1, **options)
        calls << [ :increment, name, amount, options[:expires_in] ]
        @counts[name] += amount
      end

      def delete(name, options = nil)
        calls << [ :delete, name ]
        true
      end
    end.new(calls)
    Hitch.configuration.mcp.rate_limit_store = store

    facts = system.rate_limit_store_facts
    key = calls.first.fetch(1)

    assert key.start_with?("hitch:doctor:v1:")
    refute key.start_with?("hitch:mcp:rate-limit:v1:")
    assert_equal [ [ :increment, key, 1, 5 ], [ :increment, key, 1, 5 ] ], calls.first(2)
    assert_equal [ :delete, key ], calls.last
    assert facts.fetch("counts")
    assert_equal [ 1, 2 ], facts.fetch("returned")
    refute facts.fetch("unshared")
  ensure
    Hitch.reset_configuration!
  end

  test "an admission-store probe removes its key even when counting raises" do
    system = Doctor.const_get(:System, false).new
    calls = []
    store = Class.new(ActiveSupport::Cache::Store) do
      def initialize(calls)
        super()
        @calls = calls
      end

      def increment(name, amount = 1, **options)
        @calls << [ :increment, name ]
        raise Errno::ECONNREFUSED, "store gone"
      end

      def delete(name, options = nil)
        @calls << [ :delete, name ]
        true
      end
    end.new(calls)
    Hitch.configuration.mcp.rate_limit_store = store

    assert_raises(Errno::ECONNREFUSED) { system.rate_limit_store_facts }
    assert_equal :delete, calls.last.first
    assert_equal calls.first.fetch(1), calls.last.fetch(1)
  ensure
    Hitch.reset_configuration!
  end

  test "real configuration probe reports the production DCR store contract" do
    system = Doctor.const_get(:System, false).new
    Hitch.reset_configuration!
    Hitch.configure do |configuration|
      configuration.resource_uri = "https://doctor.example/mcp"
      configuration.dynamic_client_registration_enabled = true
    end
    production = ActiveSupport::EnvironmentInquirer.new("production")

    stub_class_method(Rails, :env, -> { production }) do
      error = assert_raises(ArgumentError) { system.validate_configuration! }
      assert_includes error.message, "cannot count one caller's"
    end
  ensure
    Hitch.reset_configuration!
  end

  test "real configuration probe drives an explicit production DCR store, not just its class" do
    system = Doctor.const_get(:System, false).new
    Hitch.reset_configuration!
    outage_store = Class.new(ActiveSupport::Cache::Store) do
      def increment(_name, _amount = 1, **) = nil
      def delete(_name, _options = nil) = true
    end.new
    Hitch.configure do |configuration|
      configuration.resource_uri = "https://doctor.example/mcp"
      configuration.dynamic_client_registration_enabled = true
      configuration.dynamic_client_registration_rate_store = outage_store
    end
    production = ActiveSupport::EnvironmentInquirer.new("production")

    stub_class_method(Rails, :env, -> { production }) do
      error = assert_raises(Hitch::DynamicRegistrationRateLimit::Unavailable) do
        system.validate_configuration!
      end
      assert_includes error.message, "cannot count registration attempts"
    end
  ensure
    Hitch.reset_configuration!
  end

  test "a DCR store with neither increment nor delete still yields a report, not a crash" do
    # Base Store raises NotImplementedError (a ScriptError) from both methods;
    # the probe and its ensure-cleanup must each survive that.
    system = Doctor.const_get(:System, false).new
    Hitch.reset_configuration!
    Hitch.configure do |configuration|
      configuration.resource_uri = "https://doctor.example/mcp"
      configuration.dynamic_client_registration_enabled = true
      configuration.dynamic_client_registration_rate_store = ActiveSupport::Cache::Store.new
    end
    production = ActiveSupport::EnvironmentInquirer.new("production")

    stub_class_method(Rails, :env, -> { production }) do
      error = assert_raises(Hitch::DynamicRegistrationRateLimit::Unavailable) do
        system.validate_configuration!
      end
      assert_includes error.message, "cannot count registration attempts"
    end
  ensure
    Hitch.reset_configuration!
  end

  test "real route probe detects a dynamic predecessor that recognizes the MCP path" do
    original_resource = Hitch.configuration.resource_uri
    Hitch.configuration.resource_uri = "https://dummy.test/mcp"
    Rails.application.routes.draw do
      match "*path", to: "host_forms#create", via: :all
      match "mcp", to: "mcp#handle", via: :all
      mount Hitch::Engine => "/"
    end

    facts = Doctor.const_get(:System, false).new.route_facts

    assert_equal [ 1 ], facts.fetch("endpoint_indexes")
    assert_empty facts.fetch("same_path_predecessor_indexes")
    assert_equal false, facts.fetch("endpoint_reachable")
    assert_equal({ "controller" => "host_forms", "action" => "create" },
      facts.dig("recognized_targets", "post"))
    assert_equal({ "controller" => "host_forms", "action" => "create" },
      facts.dig("recognized_targets", "options"))
  ensure
    Rails.application.reload_routes!
    Hitch.configuration.resource_uri = original_resource
  end

  test "real route probe honors the canonical host when checking predecessors" do
    original_resource = Hitch.configuration.resource_uri
    Hitch.configuration.resource_uri = "https://doctor.example/mcp"
    Rails.application.routes.draw do
      constraints host: "doctor.example" do
        match "*path", to: "host_forms#create", via: :all
      end
      match "mcp", to: "mcp#handle", via: :all
      mount Hitch::Engine => "/"
    end

    facts = Doctor.const_get(:System, false).new.route_facts

    assert_equal false, facts.fetch("endpoint_reachable")
    assert_equal({ "controller" => "host_forms", "action" => "create" },
      facts.dig("recognized_targets", "post"))
  ensure
    Rails.application.reload_routes!
    Hitch.configuration.resource_uri = original_resource
  end

  test "real route probe checks non-POST methods that the endpoint must own" do
    original_resource = Hitch.configuration.resource_uri
    Hitch.configuration.resource_uri = "https://dummy.test/mcp"
    Rails.application.routes.draw do
      get "*path", to: "host_forms#create"
      match "mcp", to: "mcp#handle", via: :all
      mount Hitch::Engine => "/"
    end

    facts = Doctor.const_get(:System, false).new.route_facts

    assert_equal false, facts.fetch("endpoint_reachable")
    assert_equal({ "controller" => "host_forms", "action" => "create" },
      facts.dig("recognized_targets", "get"))
    assert_equal({ "controller" => "mcp", "action" => "handle" },
      facts.dig("recognized_targets", "post"))
  ensure
    Rails.application.reload_routes!
    Hitch.configuration.resource_uri = original_resource
  end

  test "real route probe checks every method Rails can recognize" do
    original_resource = Hitch.configuration.resource_uri
    Hitch.configuration.resource_uri = "https://dummy.test/mcp"
    Rails.application.routes.draw do
      match "*path", to: "host_forms#create", via: :trace
      match "mcp", to: "mcp#handle", via: :all
      mount Hitch::Engine => "/"
    end

    facts = Doctor.const_get(:System, false).new.route_facts

    assert_equal ActionDispatch::Request::HTTP_METHODS.map(&:downcase), facts.fetch("recognized_targets").keys
    assert_equal false, facts.fetch("endpoint_reachable")
    assert_equal({ "controller" => "host_forms", "action" => "create" },
      facts.dig("recognized_targets", "trace"))
    assert_equal({ "controller" => "mcp", "action" => "handle" },
      facts.dig("recognized_targets", "post"))
  ensure
    Rails.application.reload_routes!
    Hitch.configuration.resource_uri = original_resource
  end

  test "route check fails when recognition is shadowed without an exact-path predecessor" do
    system = FixtureSystem.new(HEALTHY_FULL)
    shadowed = system.route_facts.merge(
      "endpoint_reachable" => false,
      "same_path_predecessor_indexes" => [],
      "recognized_targets" => {
        "post" => { "controller" => "host_forms", "action" => "create" },
        "options" => { "controller" => "host_forms", "action" => "create" }
      }
    )

    report = stub_class_method(system, :route_facts, -> { shadowed }) do
      Doctor.call(system:)
    end
    check = report.checks.find { |candidate| candidate.id == "route_order" }

    assert_equal "fail", check.status
    assert_equal "shadowed", check.code
  end

  private

  def expected_overall(report)
    if report.checks.any? { |check| check.status == "fail" } then "error"
    elsif report.checks.any? { |check| check.status == "warn" } then "warning"
    else "ok"
    end
  end

  def expected_outcomes
    [
      [ "configuration", "fail", "invalid" ],
      [ "resource_discovery", "fail", "mismatch" ],
      [ "route_order", "fail", "missing_endpoint" ],
      [ "route_order", "fail", "shadowed" ],
      [ "route_order", "fail", "after_engine" ],
      [ "route_order", "fail", "wrong_verbs" ],
      [ "route_order", "fail", "invalid_engine_mount" ],
      [ "migrations", "fail", "missing" ],
      [ "registry", "fail", "invalid" ],
      [ "registry", "warn", "empty" ],
      [ "hosts", "fail", "blocked" ],
      [ "origins", "warn", "insecure_http" ],
      [ "rate_limit_store", "warn", "unshared" ],
      [ "rate_limit_store", "warn", "uncountable" ],
      [ "rate_limit_store", "fail", "unshared" ],
      [ "rate_limit_store", "fail", "uncountable" ]
    ]
  end

  def scenario_label(scenario)
    "scenario #{scenario.fetch('id')}: #{scenario.fetch('values')}"
  end
end
