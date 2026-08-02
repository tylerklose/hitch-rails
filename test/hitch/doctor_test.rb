# frozen_string_literal: true

require "test_helper"
require "hitch/doctor"
require "fileutils"
require "json"
require "set"
require "tmpdir"

class Hitch::DoctorTest < ActiveSupport::TestCase
  Doctor = Hitch.const_get(:Doctor, false)
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
    "redis" => "healthy",
    "package" => "complete",
    "legacy" => "absent"
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
    "redis" => "unreachable",
    "package" => "complete",
    "legacy" => "absent"
  }.freeze

  class FixtureSystem
    attr_reader :redis_probe_calls

    def initialize(values)
      @values = values
      @redis_probe_calls = 0
    end

    def versions
      { "hitch" => "0.2.0.pre.4", "rails" => "8.1.3", "ruby" => "3.4.7", "mcp" => "1.1.0" }
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
        "same_path_predecessor_indexes" => [],
        "engine_mount_indexes" => [ 3 ],
        "engine_mount_paths" => [ "/" ]
      }
      case values.fetch("route")
      when "missing" then facts["endpoint_indexes"] = []
      when "shadowed" then facts["same_path_predecessor_indexes"] = [ 1 ]
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
        "required_versions" => [ "20260801090000" ],
        "missing_versions" => [],
        "missing_tables" => [],
        "redirect_cutover_version" => 2
      }
      if values.fetch("migrations") == "missing"
        facts["missing_versions"] = [ "20260801090000" ]
        facts["missing_tables"] = [ "hitch_schema_states" ]
      elsif values.fetch("migrations") == "cutover_legacy"
        facts["redirect_cutover_version"] = 1
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

    def redis_url
      return if values.fetch("redis") == "absent"

      "redis://:redis-super-secret@redis.internal:6379/15"
    end

    def redis_target
      "redis://redis.internal:6379/15"
    end

    def redis_probe
      @redis_probe_calls += 1
      raise RuntimeError, "redis://:redis-super-secret@redis.internal:6379/15" if
        values.fetch("redis") == "unreachable"

      if values.fetch("redis") == "non_atomic"
        return { "connected" => true, "atomicity" => false, "expiry_ms" => -1, "cleanup" => false }
      end

      { "connected" => true, "atomicity" => true, "expiry_ms" => 4_999, "cleanup" => true }
    end

    def package_facts
      missing = values.fetch("package") == "missing" ? [ "lib/hitch/doctor.rb" ] : []
      {
        "artifact_version" => "0.2.0.pre.4",
        "missing_required_files" => missing,
        "missing_on_disk_files" => [],
        "forbidden_files" => []
      }
    end

    def legacy_facts
      routes = case values.fetch("legacy")
      when "absent" then []
      when "noncanonical" then [ { "index" => 1, "path" => "/old_mcp", "controller" => "old_mcp" } ]
      when "canonical" then [ { "index" => 1, "path" => "/mcp", "controller" => "old_mcp" } ]
      end
      { "routes" => routes, "canonical_routes" => routes.select { |route| route.fetch("path") == "/mcp" } }
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
      assert_operator system.redis_probe_calls, :<=, 1, scenario_label(scenario)

      rendered = Doctor.render(report, format: "json")
      refute_includes rendered, "redis-super-secret", scenario_label(scenario)
      refute_includes rendered, "credential-secret", scenario_label(scenario)
      refute_includes rendered, "internal-secret", scenario_label(scenario)
    end

    expected_outcomes.each { |outcome| assert_includes seen, outcome }
  end

  test "healthy full runtime and auth-only modes have exact skip semantics" do
    full_report = Doctor.call(system: FixtureSystem.new(HEALTHY_FULL))
    assert_equal "ok", full_report.status
    assert_equal false, full_report.failure?
    redis_codes = %w[redis_connectivity redis_atomicity_expiry].map do |id|
      full_report.checks.find { |check| check.id == id }.code
    end
    assert_equal [ "connected", "verified" ], redis_codes

    auth_report = Doctor.call(system: FixtureSystem.new(HEALTHY_AUTH_ONLY))
    assert_equal "ok", auth_report.status
    skipped_codes = %w[route_order registry redis_connectivity redis_atomicity_expiry].map do |id|
      auth_report.checks.find { |check| check.id == id }.code
    end
    assert_equal Array.new(4, "runtime_disabled"), skipped_codes
  end

  test "human and JSON rendering are deterministic frozen public shapes" do
    report = Doctor.call(system: FixtureSystem.new(HEALTHY_FULL))
    human = Doctor.render(report, format: "human")
    machine = JSON.parse(Doctor.render(report, format: "json"))

    assert_equal "Hitch doctor v1: OK", human.lines.first.chomp
    assert_includes human, "PASS versions"
    assert_includes human, "Summary: pass=12 warn=0 fail=0 skip=0"
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

  test "real Redis probe uses an isolated expiring key and always removes it" do
    system_class = Doctor.const_get(:System, false)
    system = system_class.new
    calls = []
    client = Object.new
    client.define_singleton_method(:ping) { calls << [ :ping ]; "PONG" }
    client.define_singleton_method(:eval) do |script, keys, arguments|
      calls << [ :eval, script, keys, arguments ]
      [ 1, 2, 4_999, 1 ]
    end
    client.define_singleton_method(:del) { |key| calls << [ :del, key ]; 0 }
    client.define_singleton_method(:close) { calls << [ :close ]; nil }
    redis_url = "redis://:redis-super-secret@redis.internal/15"
    Hitch.configuration.mcp.rate_limit_redis_url = redis_url
    assert_equal "redis://redis.internal:6379/15", system.redis_target

    replacement = lambda do |**options|
      calls << [ :new, options ]
      client
    end
    stub_class_method(Redis, :new, replacement) do
      result = system.redis_probe
      eval_call = calls.find { |call| call.first == :eval }
      key = eval_call.fetch(2).fetch(0)

      assert_equal redis_url, calls.find { |call| call.first == :new }.fetch(1).fetch(:url)
      assert key.start_with?("hitch:doctor:v1:")
      refute key.start_with?("hitch:mcp:rate-limit:v1:")
      assert_equal [ 5_000 ], eval_call.fetch(3)
      assert_equal [ true, true, 4_999, true ],
        result.values_at("connected", "atomicity", "expiry_ms", "cleanup")
      assert_includes calls, [ :del, key ]
      assert_includes calls, [ :close ]
    end
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
      assert_raises(Hitch::DynamicRegistrationRateLimit::Unavailable) do
        system.validate_configuration!
      end
    end
  ensure
    Hitch.reset_configuration!
  end

  test "installed package fallback inspects disk when the loaded gemspec omits files" do
    system_class = Doctor.const_get(:System, false)
    system = system_class.new
    required = system_class.const_get(:REQUIRED_PACKAGE_FILES, false) +
      Dir[Hitch::Engine.root.join("db/migrate/*.rb")].map { |path| "db/migrate/#{File.basename(path)}" }

    Dir.mktmpdir("hitch-doctor-package") do |root|
      required.each do |relative_path|
        absolute_path = File.join(root, relative_path)
        FileUtils.mkdir_p(File.dirname(absolute_path))
        File.write(absolute_path, "fixture\n")
      end
      specification = Struct.new(:version, :full_gem_path, :files).new(
        Gem::Version.new("0.2.0.pre.4"),
        root,
        []
      )
      loaded_specs = Gem.loaded_specs.merge("hitch-rails" => specification)

      stub_class_method(Gem, :loaded_specs, -> { loaded_specs }) do
        facts = system.package_facts

        assert_empty facts.fetch("missing_required_files")
        assert_empty facts.fetch("missing_on_disk_files")
        assert_empty facts.fetch("forbidden_files")
      end
    end
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
      [ "migrations", "fail", "cutover_not_current" ],
      [ "registry", "fail", "invalid" ],
      [ "registry", "warn", "empty" ],
      [ "hosts", "fail", "blocked" ],
      [ "origins", "warn", "insecure_http" ],
      [ "redis_connectivity", "warn", "memory_nonproduction" ],
      [ "redis_connectivity", "fail", "required_missing" ],
      [ "redis_connectivity", "fail", "unavailable" ],
      [ "redis_atomicity_expiry", "fail", "invalid" ],
      [ "package", "fail", "incomplete" ],
      [ "legacy_endpoint", "warn", "present_noncanonical" ],
      [ "legacy_endpoint", "fail", "canonical" ]
    ]
  end

  def scenario_label(scenario)
    "scenario #{scenario.fetch('id')}: #{scenario.fetch('values')}"
  end
end
