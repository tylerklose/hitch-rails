# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "open3"

class Hitch::MCP::ResultEvidenceTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  EVIDENCE_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/tool/result-normalization.json")
  SOURCE_FILES = {
    "result_sha256" => "app/models/hitch/mcp/result.rb",
    "result_normalizer_sha256" => "app/models/hitch/mcp/internal/result_normalizer.rb",
    "error_normalizer_sha256" => "app/models/hitch/mcp/internal/error_normalizer.rb",
    "response_normalizer_sha256" => "app/models/hitch/mcp/internal/sdk_adapter/response_normalizer.rb",
    "tool_sha256" => "app/models/hitch/mcp/tool.rb",
    "configuration_sha256" => "lib/hitch/mcp/configuration.rb",
    "result_test_sha256" => "test/hitch/mcp/result_test.rb",
    "lattice_sha256" => "test/lattice/mcp_result_normalization.json",
    "work_packet_sha256" => "docs/work_packets/M4.2.md",
    "conformance_fixture_sha256" => "test/conformance/server/fixture_tools.rb",
    "wire_fixture_sha256" => "test/dummy/app/controllers/mcp_controller.rb"
  }.freeze

  setup do
    @raw_evidence = EVIDENCE_PATH.read
    @evidence = JSON.parse(@raw_evidence)
    @source = @evidence.fetch("source")
  end

  test "evidence resolves to the immutable M4.2 implementation candidate" do
    assert_equal "hitch.m4.2-result-normalization-evidence.v1", @evidence.fetch("schema")
    assert_equal "M4.2", @evidence.fetch("milestone")
    assert_equal "accepted_internal_result_boundary", @evidence.fetch("status")
    assert_equal "immutable_implementation_candidate", @source.fetch("state")
    assert_equal true, @source.fetch("worktree_clean_at_capture")

    commit = @source.fetch("commit")
    tree = @source.fetch("tree")
    assert_match(/\A[0-9a-f]{40}\z/, commit)
    assert_match(/\A[0-9a-f]{40}\z/, tree)
    assert_equal tree, git!("rev-parse", "#{commit}^{tree}").strip
    assert_equal @source.fetch("predecessor_commit"), git!("rev-parse", "#{commit}^").strip
    assert_predicate git_status("merge-base", "--is-ancestor", commit, "HEAD"), :success?
    assert_includes git!("show", "#{commit}:lib/hitch/version.rb"),
      %(VERSION = "#{@evidence.dig('artifact', 'version')}")

    artifact = @evidence.fetch("artifact")
    assert_equal "internal_only", artifact.fetch("distribution")
    assert_equal false, artifact.fetch("checkpoint_sealed")
    assert_equal false, artifact.fetch("published")
    assert_equal false, artifact.fetch("tag_created")
    assert_equal false, artifact.fetch("github_release_created")
    assert_equal false, artifact.fetch("rubygems_publication_performed")
  end

  test "checksums bind the result schema SDK and error boundaries" do
    SOURCE_FILES.each do |evidence_key, path|
      source = git!("show", "#{@source.fetch('commit')}:#{path}")
      assert_equal @evidence.dig("checksums", evidence_key), Digest::SHA256.hexdigest(source), path
    end
  end

  test "evidence fixes the closed Result and exact cap contract" do
    contract = @evidence.fetch("result_contract")
    assert_equal %w[
      Hitch::MCP::Result.text
      Hitch::MCP::Result.structured
      Hitch::MCP::Result.error
    ], contract.fetch("public_constructors")
    assert_equal false, contract.fetch("public_generic_constructor")
    assert_equal false, contract.fetch("public_allocate")
    assert_equal "exact_Hitch_MCP_Result_instance", contract.fetch("accepted_host_return")
    assert_equal false, contract.fetch("result_subclasses_accepted")
    assert_equal false, contract.fetch("implicit_hash_or_model_serialization")
    assert_equal true, contract.fetch("constructor_inputs_copied")
    assert_equal true, contract.fetch("constructor_values_deeply_frozen")
    assert_equal true, contract.fetch("structured_output_schema_required")
    assert_equal true, contract.fetch("hitch_schema_validation_before_sdk")
    assert_equal true, contract.fetch("sdk_result_validation_backstop_enabled")
    assert_equal "JSON.generate(canonical_result).bytesize <= max_result_bytes",
      contract.fetch("serialized_cap_expression")
    assert_equal "inclusive", contract.fetch("cap_boundary")
    assert_equal 1_048_576, contract.fetch("max_result_bytes_default")
    assert_equal "Result.error_only", contract.fetch("explicit_public_error_source")
    assert_equal "generic_tool_error", contract.fetch("all_other_failures")

    boundaries = @evidence.fetch("serialized_boundaries").index_by { |vector| vector.fetch("vector_id") }
    assert_equal %w[explicit_error_exact_cap structured_exact_cap text_exact_cap], boundaries.keys.sort
    assert_equal [ 74, 74, 73 ],
      boundaries.fetch("text_exact_cap").values_at(
        "serialized_bytes", "accepted_limit_bytes", "rejected_limit_bytes"
      )
    assert_equal [ 113, 113, 112 ],
      boundaries.fetch("structured_exact_cap").values_at(
        "serialized_bytes", "accepted_limit_bytes", "rejected_limit_bytes"
      )
    assert_equal [ 75, 75, 74 ],
      boundaries.fetch("explicit_error_exact_cap").values_at(
        "serialized_bytes", "accepted_limit_bytes", "rejected_limit_bytes"
      )
    assert boundaries.values.all? { |vector| vector.fetch("over_outcome") == "generic_error" }
  end

  test "Lattice evidence enumerates all fourteen result terminal paths" do
    lattice = @evidence.fetch("lattice")
    assert_equal 42, lattice.fetch("seed")
    assert_equal 3, lattice.fetch("strength")
    assert_equal 14, lattice.fetch("valid_terminal_paths")
    assert_equal 96, lattice.fetch("exhaustive_assignments_considered")
    assert_equal "100.0%", lattice.fetch("coverage")

    rows = lattice.fetch("rows")
    assert_equal (1..14).to_a, rows.map { |row| row.fetch("id") }
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
    ], rows.map { |row| row.values_at("result_path", "wire_size", "public_outcome") }
  end

  test "failure categories and Rails error reporting remain structural and nonleaking" do
    assert_equal({
      "invalid_return" => "invalid_result_type",
      "missing_output_schema" => "missing_output_schema",
      "schema_rejection" => "output_schema_mismatch",
      "oversize_result" => "result_too_large",
      "serialization_failure" => "serialization_failure",
      "host_exception" => "host_execution"
    }, @evidence.fetch("failure_categories"))

    reporting = @evidence.fetch("error_reporting")
    assert_equal "synthetic_framework_wrapper", reporting.fetch("reported_exception")
    assert_equal false, reporting.fetch("original_exception_reported")
    assert_equal false, reporting.fetch("reported_wrapper_cause_present")
    assert_equal false, reporting.fetch("unsafe_request_id_reported")
    assert_equal false, reporting.fetch("expected_forbidden_reported")
    assert_equal false, reporting.fetch("reporter_failure_changes_public_response")
    assert_equal false, reporting.fetch("system_stack_failure_escapes_boundary")
    assert_equal 0, reporting.fetch("global_sdk_callback_observations")
    assert_equal 0, reporting.fetch("response_canary_matches")
    assert_equal 0, reporting.fetch("subscriber_log_canary_matches")
    assert_equal 0, reporting.fetch("reported_backtrace_canary_matches")
    assert_equal 0, reporting.fetch("ephemeral_rails_log_canary_matches")
    assert_equal false, reporting.fetch("raw_log_retained_in_repository")
  end

  test "mutation evidence is explicitly oracle-only until the M4.5 runner" do
    mutation = @evidence.fetch("mutation_oracles")
    assert_equal false, mutation.fetch("runner_executed")
    assert_equal "M4.5", mutation.fetch("runner_owner")
    assert_equal "named_test_oracles_not_an_executed_mutation_score", mutation.fetch("classification")
    assert mutation.fetch("oracles").all? { |oracle| oracle.fetch("oracle_status") == "would_fail_named_test" }
    assert mutation.fetch("oracles").all? { |oracle| oracle.fetch("test").start_with?("test_") }
  end

  test "acceptance spans focused SDK Rails contract wire and conformance lanes" do
    focused = @evidence.dig("acceptance", "focused_default")
    assert_equal [ 12, 204, 0, 0, 0 ],
      focused.values_at("runs", "assertions", "failures", "errors", "skips")

    regression = @evidence.dig("acceptance", "runtime_regression")
    assert_equal [ 98, 1537, 0, 0, 0 ],
      regression.values_at("runs", "assertions", "failures", "errors", "skips")

    sdk_lanes = @evidence.dig("acceptance", "sdk_lanes")
    assert_equal %w[min latest], sdk_lanes.map { |lane| lane.fetch("name") }
    assert sdk_lanes.all? { |lane| lane.fetch("resolved") == "1.1.0" }
    assert sdk_lanes.all? { |lane| lane.values_at("failures", "errors", "skips") == [ 0, 0, 0 ] }
    assert_equal [ 321, 320 ], sdk_lanes.map { |lane| lane.fetch("assertions") }

    rails_profiles = @evidence.dig("acceptance", "rails_profiles")
    assert_equal %w[rails_7_2_sqlite rails_8_1_postgresql],
      rails_profiles.map { |profile| profile.fetch("name") }
    assert rails_profiles.all? { |profile| profile.fetch("runs") == 52 }
    assert rails_profiles.all? { |profile| profile.values_at("failures", "errors", "skips") == [ 0, 0, 0 ] }
    assert_equal [ 641, 827 ], rails_profiles.map { |profile| profile.fetch("assertions") }

    contract = @evidence.dig("acceptance", "contract")
    assert_equal [ 43, 686, 0, 0, 0, 14 ],
      contract.values_at(
        "runs", "assertions", "failures", "errors", "skips", "result_lattice_terminal_rows"
      )

    wire_lanes = @evidence.dig("acceptance", "wire_lanes")
    assert_equal %w[min latest], wire_lanes.map { |lane| lane.fetch("name") }
    assert wire_lanes.all? { |lane| lane.fetch("vectors") == 44 }
    assert wire_lanes.all? { |lane| lane.values_at("runs", "assertions") == [ 16, 1549 ] }
    assert wire_lanes.all? { |lane| lane.values_at("failures", "errors", "skips") == [ 0, 0, 0 ] }

    conformance = @evidence.dig("acceptance", "server_conformance")
    assert_equal @source.fetch("commit"), conformance.fetch("source_commit")
    assert_equal @source.fetch("tree"), conformance.fetch("source_tree")
    assert_equal true, conformance.fetch("worktree_clean_at_run")
    assert_equal [ 49, 2, 5, 0 ],
      conformance.values_at("success", "expected_failure", "capability_gated_skip", "unexpected_failure")
    assert_equal false, conformance.fetch("credential_in_output_or_logs")

    assert_equal "deferred_to_M4.5_checkpoint", @evidence.dig("acceptance", "full_ci")
    assert_equal "deferred_to_M4.5_checkpoint", @evidence.dig("acceptance", "package_smoke")
    assert_equal "deferred_to_M4.5_checkpoint", @evidence.dig("acceptance", "mutation_runner")
  end

  test "evidence contains no credentials arguments results or original exceptions" do
    assert @evidence.fetch("sensitive_data").values.none?
    refute_match(/Bearer\s+[A-Za-z0-9_-]+/, @raw_evidence)
    refute_match(
      /argument-canary|host-exception-canary|principal-canary|token-canary|scope-canary|client-canary|meta-canary/,
      @raw_evidence
    )
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
