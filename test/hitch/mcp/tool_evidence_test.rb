# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "open3"

class Hitch::MCP::ToolEvidenceTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  EVIDENCE_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/tool/authorization-denials.json")
  SOURCE_FILES = {
    "tool_sha256" => "app/models/hitch/mcp/tool.rb",
    "forbidden_sha256" => "app/models/hitch/mcp/forbidden.rb",
    "registry_sha256" => "app/models/hitch/mcp/registry.rb",
    "sdk_adapter_sha256" => "app/models/hitch/mcp/internal/sdk_adapter.rb",
    "tool_test_sha256" => "test/hitch/mcp/tool_test.rb",
    "lattice_sha256" => "test/lattice/mcp_tool_authorization.json",
    "work_packet_sha256" => "docs/work_packets/M4.1.md",
    "conformance_fixture_sha256" => "test/conformance/server/fixture_tools.rb",
    "wire_fixture_sha256" => "test/dummy/app/controllers/mcp_controller.rb"
  }.freeze

  setup do
    @raw_evidence = EVIDENCE_PATH.read
    @evidence = JSON.parse(@raw_evidence)
    @source = @evidence.fetch("source")
  end

  test "evidence resolves to the immutable M4.1 implementation candidate" do
    assert_equal "hitch.m4.1-authorization-denial-evidence.v1", @evidence.fetch("schema")
    assert_equal "M4.1", @evidence.fetch("milestone")
    assert_equal "accepted_internal_tool_policy_boundary", @evidence.fetch("status")
    assert_equal "immutable_implementation_candidate", @source.fetch("state")
    assert_equal true, @source.fetch("worktree_clean_at_capture")

    commit = @source.fetch("commit")
    tree = @source.fetch("tree")
    assert_match(/\A[0-9a-f]{40}\z/, commit)
    assert_match(/\A[0-9a-f]{40}\z/, tree)
    assert_equal tree, git!("rev-parse", "#{commit}^{tree}").strip
    assert_predicate git_status("merge-base", "--is-ancestor", commit, "HEAD"), :success?
    assert_includes git!("show", "#{commit}:lib/hitch/version.rb"),
      %(VERSION = "#{@evidence.dig('artifact', 'version')}")

    artifact = @evidence.fetch("artifact")
    assert_equal "internal_only", artifact.fetch("distribution")
    assert_equal false, artifact.fetch("checkpoint_sealed")
    assert_equal false, artifact.fetch("published")
    assert_equal false, artifact.fetch("rubygems_publication_performed")
  end

  test "checksums bind the final call policy and compatibility boundaries" do
    SOURCE_FILES.each do |evidence_key, path|
      source = git!("show", "#{@source.fetch('commit')}:#{path}")
      assert_equal @evidence.dig("checksums", evidence_key), Digest::SHA256.hexdigest(source), path
    end
  end

  test "evidence fixes schema normalization policy and execution precedence" do
    assert_equal %w[
      registration
      request_local_availability
      static_oauth_scope
      sdk_input_schema
      argument_normalization
      host_argument_policy
      host_execution
    ], @evidence.fetch("gate_precedence")

    contract = @evidence.fetch("call_contract")
    assert_equal true, contract.fetch("framework_owned_call")
    assert_equal false, contract.fetch("subclass_call_override_admitted_by_registry")
    assert_equal "pinned_mcp_sdk_before_tool_callback", contract.fetch("schema_authority")
    assert_equal "deeply_frozen", contract.fetch("argument_mutability")
    assert_equal "same_object", contract.fetch("argument_identity_between_policy_and_perform")
    assert_equal "deny_by_Hitch_MCP_Forbidden", contract.fetch("authorization_default")
    assert_equal false, contract.fetch("perform_after_denial")
    assert_equal false, contract.fetch("exception_messages_public")
    assert_equal "deferred_to_M4.2", contract.fetch("supported_result_channel")
  end

  test "denial paths perform no work after policy rejection and reveal no messages" do
    paths = @evidence.fetch("denial_paths").index_by { |path| path.fetch("name") }
    assert_equal %w[
      default_policy
      duplicate_normalized_key
      explicit_forbidden
      non_json_value
      sdk_schema_invalid
      top_level_reserved_context
      unexpected_policy_failure
    ], paths.keys.sort

    paths.each_value do |path|
      assert_equal 0, path.fetch("perform_attempts")
    end
    assert_equal 0, paths.fetch("sdk_schema_invalid").fetch("authorization_attempts")
    assert_equal 0, paths.fetch("top_level_reserved_context").fetch("tool_callback_entries")
    assert_equal 0, paths.fetch("non_json_value").fetch("authorization_attempts")
    assert_equal false, paths.fetch("explicit_forbidden").fetch("exception_message_present")
    assert_equal false, paths.fetch("unexpected_policy_failure").fetch("exception_message_present")

    admitted = @evidence.fetch("admitted_control_paths").index_by { |path| path.fetch("name") }
    assert_equal false, admitted.fetch("normal_return_with_false_value").fetch("return_value_used_as_authority")
    assert_equal 1, admitted.fetch("host_exception").fetch("perform_attempts")
    assert_equal false, admitted.fetch("host_exception").fetch("exception_message_present")
    assert_equal true, admitted.fetch("successful_control_flow").fetch("same_argument_identity")
    assert_equal false, admitted.fetch("successful_control_flow").fetch("output_contract_complete")
  end

  test "Lattice rows bind the schema denial policy denial and host exception paths" do
    lattice = @evidence.fetch("lattice")
    assert_equal 8, lattice.fetch("strength")
    assert_equal 12, lattice.fetch("valid_terminal_paths")
    assert_equal "100.0%", lattice.fetch("coverage")
    rows = lattice.fetch("selected_control_flow_rows").index_by { |row| row.fetch("row") }
    assert_equal [ 1, 9, 10, 12 ], rows.keys.sort
    assert_equal "not_applicable", rows.fetch(9).fetch("argument_policy")
    assert_equal "not_applicable", rows.fetch(10).fetch("host_outcome")
    assert_equal "raises", rows.fetch(12).fetch("host_outcome")
    assert_equal "deferred_to_M4.2", lattice.fetch("output_semantics")
  end

  test "mutation evidence is explicitly oracle-only until the M4.5 runner" do
    mutation = @evidence.fetch("mutation_oracles")
    assert_equal false, mutation.fetch("runner_executed")
    assert_equal "M4.5", mutation.fetch("runner_owner")
    assert_equal "named_test_oracles_not_an_executed_mutation_score", mutation.fetch("classification")
    assert mutation.fetch("oracles").all? { |oracle| oracle.fetch("oracle_status") == "would_fail_named_test" }
    assert mutation.fetch("oracles").all? { |oracle| oracle.fetch("test").start_with?("test_") }
  end

  test "acceptance spans SDK Rails wire contract and conformance lanes" do
    focused = @evidence.dig("acceptance", "focused_default")
    assert_equal [ 10, 80, 0, 0, 0 ],
      focused.values_at("runs", "assertions", "failures", "errors", "skips")

    regression = @evidence.dig("acceptance", "regression")
    assert_equal [ 74, 2717, 0, 0, 0 ],
      regression.values_at("runs", "assertions", "failures", "errors", "skips")

    sdk_lanes = @evidence.dig("acceptance", "sdk_lanes")
    assert_equal %w[min latest], sdk_lanes.map { |lane| lane.fetch("name") }
    assert sdk_lanes.all? { |lane| lane.fetch("resolved") == "1.1.0" }
    assert sdk_lanes.all? { |lane| lane.values_at("failures", "errors", "skips") == [ 0, 0, 0 ] }

    rails_profiles = @evidence.dig("acceptance", "rails_profiles")
    assert_equal %w[rails_7_2_sqlite rails_8_1_postgresql],
      rails_profiles.map { |profile| profile.fetch("name") }
    assert rails_profiles.all? { |profile| profile.fetch("runs") == 28 }
    assert rails_profiles.all? { |profile| profile.values_at("failures", "errors", "skips") == [ 0, 0, 0 ] }

    wire_lanes = @evidence.dig("acceptance", "wire_lanes")
    assert_equal %w[min latest], wire_lanes.map { |lane| lane.fetch("name") }
    assert wire_lanes.all? { |lane| lane.fetch("vectors") == 44 }
    assert wire_lanes.all? { |lane| lane.values_at("failures", "errors", "skips") == [ 0, 0, 0 ] }

    conformance = @evidence.dig("acceptance", "server_conformance")
    assert_equal @source.fetch("commit"), conformance.fetch("source_commit")
    assert_equal true, conformance.fetch("worktree_clean_at_run")
    assert_equal [ 49, 2, 5, 0 ],
      conformance.values_at("success", "expected_failure", "capability_gated_skip", "unexpected_failure")
    assert_equal false, conformance.fetch("credential_in_output_or_logs")

    assert_equal "deferred_to_M4.5_checkpoint", @evidence.dig("acceptance", "full_ci")
    assert_equal "deferred_to_M4.5_checkpoint", @evidence.dig("acceptance", "package_smoke")
    assert_equal "deferred_to_M4.5_checkpoint", @evidence.dig("acceptance", "mutation_runner")
  end

  test "evidence contains no credentials arguments results or exception messages" do
    assert @evidence.fetch("sensitive_data").values.none?
    refute_match(/Bearer\s+[A-Za-z0-9_-]+/, @raw_evidence)
    refute_match(/policy-secret|host-execution-secret|unexpected-policy-secret/, @raw_evidence)
  end

  private

  def git!(*arguments)
    stdout, stderr, status = Open3.capture3("git", *arguments, chdir: REPOSITORY_ROOT.to_s)
    assert_predicate status, :success?, stderr
    stdout
  end

  def git_status(*arguments)
    _stdout, _stderr, status = Open3.capture3("git", *arguments, chdir: REPOSITORY_ROOT.to_s)
    status
  end
end
