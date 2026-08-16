# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "timeout"
require "yaml"

class McpContractArtifactsTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  REQUIRED_WIRE_IDS = %w[
    options_allowed options_origin_denied post_host_denied post_origin_denied
    forwarded_host_cannot_change_public_origin
    forwarded_proto_cannot_change_public_origin
    host_port_cannot_change_public_origin get_method_denied token_missing token_expired token_revoked
    token_wrong_audience admission_reject admission_store_failure
    content_type_missing accept_missing_sse request_body_oversize invalid_json
    duplicate_object_member malformed_envelope meta_protocol_missing
    meta_capabilities_missing meta_client_info_absent meta_client_info_invalid
    protocol_header_missing method_header_mismatch name_header_mismatch
    single_value_header_comma_combined unsupported_protocol_version
    unsupported_rpc_initialize malformed_call_params
    reserved_server_context_explicit reserved_server_context_open
    reserved_server_context_patterned reserved_server_context_referenced
    reserved_server_context_composed nested_server_context_valid
    input_schema_invalid discover_success list_success call_success
  ].freeze
  WORK_KEYS = %w[body_parses registry sdk host].freeze

  test "wire vectors have complete terminal oracles" do
    document = load_yaml("test/contracts/mcp_wire_vectors.yml")
    vectors = document.fetch("vectors")
    ids = vectors.map { |vector| vector.fetch("id") }

    assert_equal ids.uniq, ids
    assert_empty REQUIRED_WIRE_IDS - ids
    vectors.each do |vector|
      expected = vector.fetch("expected")
      assert_kind_of Integer, expected.fetch("http_status"), vector.fetch("id")
      assert_kind_of Hash, expected.fetch("headers"), vector.fetch("id")
      assert expected.key?("protocol_code"), vector.fetch("id")
      assert expected.key?("result"), vector.fetch("id")
      assert_includes [ 0, 1 ], expected.fetch("request_events"), vector.fetch("id")
      assert_includes [ 0, 1 ], expected.fetch("invocation_events"), vector.fetch("id")
      assert_equal WORK_KEYS, expected.fetch("work").keys
      assert expected.fetch("work").values.all? { |count| count.is_a?(Integer) && count >= 0 }
    end
  end

  test "lattice scenarios and terminal oracles align" do
    scenarios = JSON.parse(REPOSITORY_ROOT.join("test/lattice/mcp_tool_authorization_scenarios.json").read).fetch("scenarios")
    oracles = load_yaml("test/contracts/mcp_tool_authorization_oracles.yml").fetch("rows")

    assert_equal (1..12).to_a, scenarios.map { |row| row.fetch("id") }
    assert_equal scenarios.map { |row| row.fetch("id") }, oracles.map { |row| row.fetch("id") }
    assert_equal %w[expired revoked], oracles.find { |row| row.fetch("id") == 3 }.fetch("concrete_variants")
    assert_equal oracles[5].fetch("expected"), oracles[6].fetch("expected")
    assert_equal [ 1, 1, 1 ], [
      oracles.first.dig("expected", "request_events"),
      oracles.first.dig("expected", "invocation_events"),
      oracles.first.dig("expected", "host_calls")
    ]
  end

  test "lattice is exhaustive at strength eight" do
    lattice = working_lattice
    schema = REPOSITORY_ROOT.join("test/lattice/mcp_tool_authorization.json").to_s
    output, error, status = Timeout.timeout(30) do
      Open3.capture3(lattice, "generate", schema, "--format", "json", "--seed", "42", "--strength", "8")
    end
    assert_predicate status, :success?, error

    generated = JSON.parse(output)
    checked = JSON.parse(REPOSITORY_ROOT.join("test/lattice/mcp_tool_authorization_scenarios.json").read)
    assert_equal 12, generated.fetch("scenarios").length
    assert_equal checked.fetch("scenarios"), generated.fetch("scenarios")
  end

  test "result normalization lattice has fourteen exhaustive terminal paths" do
    lattice = working_lattice
    schema = REPOSITORY_ROOT.join("test/lattice/mcp_result_normalization.json").to_s
    output, error, status = Timeout.timeout(30) do
      Open3.capture3(lattice, "generate", schema, "--format", "json", "--seed", "42", "--strength", "3")
    end
    assert_predicate status, :success?, error

    generated = JSON.parse(output)
    rows = generated.fetch("scenarios").map { |row| row.fetch("values").values_at(*%w[result_path wire_size public_outcome]) }
    assert_equal [
      %w[text within success],
      %w[text exact success],
      %w[text over generic_error],
      %w[structured_schema_accepts within success],
      %w[structured_schema_accepts exact success],
      %w[structured_schema_accepts over generic_error],
      %w[explicit_error within explicit_safe_error],
      %w[explicit_error exact explicit_safe_error],
      %w[explicit_error over generic_error],
      %w[structured_schema_missing not_applicable generic_error],
      %w[structured_schema_rejects not_applicable generic_error],
      %w[invalid_return not_applicable generic_error],
      %w[serialization_failure not_applicable generic_error],
      %w[host_raises not_applicable generic_error]
    ], rows
  end

  test "runtime contract tracks active boundaries through M4.5 without misleading skips" do
    pending = load_yaml("test/contracts/pending_runtime_tests.yml")
    assert_equal "m2_m4_5_active", pending.fetch("runtime_status")
    probes = load_yaml("docs/contracts/sdk_probes.yml").fetch("probes")
    sdk_tests = pending.fetch("tests").find { |entry| entry.fetch("owner_issue") == "M2.1" }
    assert_equal probes.map { |probe| probe.fetch("runtime_test") }.sort,
      sdk_tests.fetch("test_names").sort

    pending.fetch("tests").each do |entry|
      path = REPOSITORY_ROOT.join(entry.fetch("path"))
      assert_predicate path, :file?
      content = path.read
      assert_includes content, entry.fetch("activation_constant")
      entry.fetch("test_names").each { |name| assert_includes content, name }
      refute_match(/^\s*(?:skip|flunk)\b/, content)
    end
  end

  test "forced suite manifest owns every M4 boundary and names executable tests" do
    manifest = load_yaml("test/contracts/mcp_m4_forced_suites.yml")
    suites = manifest.fetch("suites")
    required_boundaries = manifest.fetch("required_boundaries")

    assert_equal 1, manifest.fetch("schema_version")
    assert_equal "m2_m4_5_active", manifest.fetch("runtime_status")
    assert_equal suites.map { |suite| suite.fetch("id") }.uniq, suites.map { |suite| suite.fetch("id") }
    assert_equal suites.map { |suite| suite.fetch("path") }.uniq, suites.map { |suite| suite.fetch("path") }
    assert_empty required_boundaries - suites.flat_map { |suite| suite.fetch("boundaries") }.uniq

    suites.each do |suite|
      path = REPOSITORY_ROOT.join(suite.fetch("path"))
      assert_predicate path, :file?, suite.fetch("id")
      source = path.read
      assert_includes source, "class #{suite.fetch('test_class')} <", suite.fetch("id")
      suite.fetch("required_tests").each do |test_name|
        assert_includes source, %(test "#{test_name}"), "#{suite.fetch('id')}: #{test_name}"
      end
      refute_match(/^\s*(?:skip|flunk)\b/, source, suite.fetch("id"))
    end

    assert_equal [
      [ "generator_install_collisions", "M5.1", "bin/ci-generators install" ],
      [ "generator_tool_collisions", "M5.2", "bin/ci-generators tool" ]
    ], manifest.fetch("deferred_forced_boundaries").map { |entry| entry.values_at("id", "owner_issue", "gate") }
  end

  test "mutation gate owns one exact executable subject map" do
    command = REPOSITORY_ROOT.join("bin/mutation-mcp")
    coverage_paths = %w[
      test/mutation/mcp_coverage_test.rb
      test/mutation/mcp_post_m4_coverage_test.rb
    ]
    manifests = %w[
      test/contracts/mcp_m4_mutation_subjects.yml
      test/contracts/mcp_post_m4_mutation_subjects.yml
    ].map { |path| load_yaml(path) }

    assert_predicate command, :executable?
    coverage_paths.each { |path| assert_predicate REPOSITORY_ROOT.join(path), :file? }
    source = command.read
    declarations = coverage_paths.flat_map do |path|
      REPOSITORY_ROOT.join(path).read.scan(/cover "([^"]+)"/).flatten
    end.uniq
    subjects = manifests.flat_map { |manifest| manifest.fetch("subjects") }
    expressions = subjects.map { |subject| subject.fetch("expression") }
    domains = subjects.map { |subject| subject.fetch("domain") }.uniq

    assert manifests.all? { |manifest| manifest.fetch("schema_version") == 1 }
    assert_equal 18, expressions.length
    assert_equal expressions.uniq, expressions
    assert_equal manifests.flat_map { |manifest| manifest.fetch("required_domains") }, domains
    assert_empty expressions - declarations
    assert_includes source, "test/contracts/mcp_m4_mutation_subjects.yml"
    assert_includes source, "test/contracts/mcp_post_m4_mutation_subjects.yml"
    assert_includes source, '"--usage", "opensource"'
    assert_includes source, '"--mutation-timeout", timeout_seconds.to_s'
    assert_includes source, '"--jobs", jobs.to_s'
  end

  private

  def load_yaml(relative_path)
    YAML.safe_load_file(REPOSITORY_ROOT.join(relative_path), permitted_classes: [], aliases: false)
  end

  def working_lattice
    return ENV.fetch("LATTICE_BIN") if ENV["LATTICE_BIN"]

    ENV.fetch("PATH").split(File::PATH_SEPARATOR).each do |directory|
      candidate = File.join(directory, "lattice")
      next unless File.executable?(candidate)

      _stdout, _stderr, status = Timeout.timeout(5) { Open3.capture3(candidate, "--help") }
      return candidate if status.success?
    rescue Timeout::Error
      next
    end
    flunk "No working lattice executable found on PATH"
  end
end
