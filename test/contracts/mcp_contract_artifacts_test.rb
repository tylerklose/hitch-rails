# frozen_string_literal: true

require "test_helper"
require "json"
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

  test "mutation gate owns one exact executable subject map" do
    coverage_paths = %w[
      test/mutation/mcp_coverage_test.rb
      test/mutation/mcp_post_m4_coverage_test.rb
    ]
    manifests = %w[
      test/contracts/mcp_m4_mutation_subjects.yml
      test/contracts/mcp_post_m4_mutation_subjects.yml
    ].map { |path| load_yaml(path) }

    assert_predicate REPOSITORY_ROOT.join("bin/mutation-mcp"), :executable?
    coverage_paths.each { |path| assert_predicate REPOSITORY_ROOT.join(path), :file? }
    declarations = coverage_paths.flat_map do |path|
      REPOSITORY_ROOT.join(path).read.scan(/cover "([^"]+)"/).flatten
    end.uniq
    subjects = manifests.flat_map { |manifest| manifest.fetch("subjects") }
    expressions = subjects.map { |subject| subject.fetch("expression") }
    domains = subjects.map { |subject| subject.fetch("domain") }.uniq

    assert_equal 20, expressions.length
    assert_equal expressions.uniq, expressions
    assert_equal manifests.flat_map { |manifest| manifest.fetch("required_domains") }, domains
    assert_empty expressions - declarations
  end

  private

  def load_yaml(relative_path)
    YAML.safe_load_file(REPOSITORY_ROOT.join(relative_path), permitted_classes: [], aliases: false)
  end
end
