# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "open3"
require "time"

class Hitch::MCP::ObservationEvidenceTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  EVIDENCE_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/observation/event-contract.json")
  SOURCE_FILES = {
    "endpoint_sha256" => "app/controllers/concerns/hitch/mcp/endpoint.rb",
    "observation_sha256" => "app/models/hitch/mcp/internal/observation.rb",
    "tool_sha256" => "app/models/hitch/mcp/tool.rb",
    "sdk_adapter_sha256" => "app/models/hitch/mcp/internal/sdk_adapter.rb",
    "observation_test_sha256" => "test/hitch/mcp/observation_test.rb",
    "wire_fixture_sha256" => "test/dummy/app/controllers/mcp_controller.rb",
    "public_api_sha256" => "docs/contracts/mcp_public_api.yml",
    "invariants_sha256" => "docs/contracts/mcp_invariants.yml",
    "work_packet_sha256" => "docs/work_packets/M4.4.md",
    "package_contract_sha256" => "test/tooling/package_contract_test.rb"
  }.freeze

  setup do
    @raw_evidence = EVIDENCE_PATH.read
    @evidence = JSON.parse(@raw_evidence)
    @source = @evidence.fetch("source")
  end

  test "evidence resolves to the immutable M4.4 implementation candidate" do
    assert_equal "hitch.m4.4-observation-event-contract-evidence.v1", @evidence.fetch("schema")
    assert_equal "M4.4", @evidence.fetch("milestone")
    assert_equal "accepted_internal_observation_boundary", @evidence.fetch("status")
    assert_instance_of Time, Time.iso8601(@evidence.fetch("verified_at"))
    assert_equal "immutable_implementation_candidate", @source.fetch("state")
    assert_equal true, @source.fetch("worktree_clean_before_evidence_write")

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
    assert_equal "0.2.0.pre.3.dev", artifact.fetch("version")
    assert_equal "0.2.0.pre.3", artifact.fetch("target_checkpoint")
    assert_equal "internal_only", artifact.fetch("distribution")
    assert_equal false, artifact.fetch("checkpoint_sealed")
    assert_equal false, artifact.fetch("published")
    assert_equal false, artifact.fetch("tag_created")
    assert_equal false, artifact.fetch("github_release_created")
    assert_equal false, artifact.fetch("rubygems_publication_performed")
  end

  test "checksums bind the endpoint events SDK tests docs and package contract" do
    SOURCE_FILES.each do |evidence_key, source_file|
      source = git!("show", "#{@source.fetch('commit')}:#{source_file}")
      assert_equal @evidence.dig("checksums", evidence_key), Digest::SHA256.hexdigest(source), source_file
    end
  end

  test "request event fixes exact structural keys identities and outcomes" do
    request_event = @evidence.dig("events", "request")
    assert_equal "request.hitch_mcp", request_event.fetch("name")
    assert_equal 1, request_event.fetch("payload_version")
    assert_equal %w[
      schema_version request_id method tool_name principal_type principal_key client_key
      http_status protocol_code outcome request_bytes response_bytes duration_ms
    ], request_event.fetch("payload_keys")

    emission = request_event.fetch("emission")
    assert_equal [ 1, 0, true ], emission.values_at(
      "non_options_request_count",
      "options_request_count",
      "outer_callback_precedes_host_origin_method_auth_and_admission"
    )

    request_id = request_event.fetch("request_id")
    assert_equal "framework_generated", request_id.fetch("source")
    assert_equal "32_lowercase_hex_characters", request_id.fetch("format")
    assert_equal false, request_id.fetch("json_rpc_request_id_reused")

    identity = request_event.fetch("identity")
    assert_equal "HMAC-SHA256", identity.fetch("algorithm")
    assert_equal "hitch/mcp/observation/v1", identity.fetch("salt")
    assert_equal true, identity.fetch("principal_and_client_domains_separated")
    assert_equal true, identity.fetch("token_rotation_stable")
    assert_equal [ 64, 64 ], identity.values_at("principal_digest_characters", "client_digest_characters")
    assert_equal [ false, false ], identity.values_at(
      "raw_principal_identifier_emitted",
      "raw_client_identifier_emitted"
    )

    assert_equal %w[server/discover tools/list tools/call], request_event.fetch("method_values")
    assert_equal true, request_event.fetch("method_present_only_after_verified_request")
    assert_equal true, request_event.fetch("tool_name_present_only_after_registered_available_resolution")
    assert_equal %w[
      bad_request complete forbidden header_mismatch http_error internal_error invalid_params
      invalid_request method_not_allowed method_not_found not_acceptable not_found parse_error
      rate_limited request_too_large service_unavailable unauthorized unsupported_media_type
      unsupported_protocol
    ], request_event.fetch("fixed_outcome_categories")
  end

  test "terminal and invocation matrices fix counts and category semantics" do
    terminal = @evidence.dig("events", "request", "terminal_matrix")
    assert_equal [ 26, 1, 25, 25, 4, 25 ], terminal.values_at(
      "case_count",
      "options_cases",
      "non_options_cases",
      "request_events",
      "invocation_events",
      "outcome_assertions"
    )
    assert_equal [ 200, 204, 400, 401, 403, 404, 405, 406, 413, 415, 429, 503 ],
      terminal.fetch("http_statuses")
    assert_equal %w[
      bad_request complete forbidden header_mismatch internal_error invalid_params invalid_request
      method_not_allowed method_not_found not_acceptable parse_error rate_limited request_too_large
      service_unavailable unauthorized unsupported_media_type unsupported_protocol
    ], terminal.fetch("observed_outcome_categories")

    invocation = @evidence.dig("events", "invocation")
    assert_equal "invocation.hitch_mcp", invocation.fetch("name")
    assert_equal 1, invocation.fetch("payload_version")
    assert_equal %w[
      schema_version request_id tool_name availability argument_policy executed result_category duration_ms
    ], invocation.fetch("payload_keys")
    assert_equal 0, invocation.fetch("unknown_unavailable_scope_and_schema_terminal_events")
    assert_equal [ "available" ], invocation.fetch("availability_values")
    assert_equal %w[allowed denied failed], invocation.fetch("argument_policy_values")
    assert_equal %w[success explicit_error generic_error], invocation.fetch("result_category_values")

    category_matrix = invocation.fetch("category_matrix")
    assert_equal [ 5, 5 ], category_matrix.values_at("case_count", "events")
    assert_equal [ false, false, true, true, true ], category_matrix.values_at(
      "policy_denial_executed",
      "policy_failure_executed",
      "host_failure_executed",
      "explicit_error_executed",
      "success_executed"
    )

    correlation = @evidence.dig("events", "correlation")
    assert correlation.values.all?
  end

  test "subscriber failures and SDK callbacks cannot forward request data" do
    isolation = @evidence.fetch("subscriber_isolation")
    assert_equal [ 2, 2 ], isolation.values_at("hostile_subscriber_failures", "sanitized_reports")
    assert_equal true, isolation.fetch("successful_response_unchanged")
    assert_equal false, isolation.fetch("original_subscriber_exception_reported")
    assert_equal false, isolation.fetch("reported_wrapper_cause_present")
    assert_equal %w[hitch_mcp_category hitch_mcp_event], isolation.fetch("report_context_keys")
    assert_equal "hitch.mcp.observation", isolation.fetch("report_source")
    assert_equal false, isolation.fetch("subscriber_failure_escapes_request")

    callbacks = @evidence.fetch("sdk_callbacks")
    assert_equal 0, callbacks.fetch("global_callback_observations")
    assert callbacks.except("global_callback_observations").values.none?

    assert @evidence.fetch("sensitive_data").values.none?
  end

  test "acceptance spans focused full SDK wire rate package and quality gates" do
    focused = @evidence.dig("acceptance", "focused")
    assert_equal [ 5, 223, 0, 0, 0 ],
      focused.values_at("runs", "assertions", "failures", "errors", "skips")

    full = @evidence.dig("acceptance", "full_default")
    assert_equal [ 532, 6340, 0, 0, 0 ],
      full.values_at("runs", "assertions", "failures", "errors", "skips")

    sdk_lanes = @evidence.dig("acceptance", "sdk_lanes")
    assert_equal %w[min latest], sdk_lanes.map { |lane| lane.fetch("name") }
    assert sdk_lanes.all? { |lane| lane.fetch("runs") == 19 && lane.fetch("resolved") == "1.1.0" }
    assert_equal [ 321, 320 ], sdk_lanes.map { |lane| lane.fetch("assertions") }
    assert sdk_lanes.all? { |lane| lane.values_at("failures", "errors", "skips") == [ 0, 0, 0 ] }

    wire_lanes = @evidence.dig("acceptance", "wire_lanes")
    assert_equal %w[min latest], wire_lanes.map { |lane| lane.fetch("name") }
    assert wire_lanes.all? { |lane| lane.values_at("vectors", "runs", "assertions") == [ 44, 16, 1549 ] }
    assert wire_lanes.all? { |lane| lane.values_at("failures", "errors", "skips") == [ 0, 0, 0 ] }

    rate_lanes = @evidence.dig("acceptance", "rate_limit_lanes")
    assert_equal %w[rails_7_2_sqlite rails_8_1_postgresql],
      rate_lanes.map { |lane| lane.fetch("name") }
    assert_equal [ 160, 166 ], rate_lanes.map { |lane| lane.fetch("assertions") }
    assert rate_lanes.all? { |lane| lane.fetch("runs") == 27 }
    assert rate_lanes.all? { |lane| lane.values_at("failures", "errors", "skips") == [ 0, 0, 0 ] }

    package = @evidence.dig("acceptance", "package_smoke")
    assert_equal "bin/package-smoke", package.fetch("command")
    assert_equal 2, package.fetch("profiles").length
    assert package.except("command", "artifact_install", "profiles").values.all?
    assert package.fetch("profiles").all? do |profile|
      profile.fetch("generator_migrations_boot_oauth_mcp") == "passed"
    end

    quality = @evidence.dig("acceptance", "quality")
    assert_equal [ 187, 0, 31, 24, 15, 4, true ], quality.values_at(
      "rubocop_files",
      "rubocop_offenses",
      "documented_api_entries",
      "documented_invariants",
      "sdk_probes",
      "adrs",
      "toolchain_verified"
    )
  end

  test "evidence contains no credentials raw identities request data or canaries" do
    refute_match(/Bearer\s+[A-Za-z0-9_-]+/, @raw_evidence)
    refute_match(/observation-(?:principal|client|other)/, @raw_evidence)
    refute_match(/argument-canary|token-canary|result-canary|subscriber-secret|scope-failure-canary/,
      @raw_evidence)
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
