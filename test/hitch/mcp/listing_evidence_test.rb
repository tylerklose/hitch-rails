# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "open3"

class Hitch::MCP::ListingEvidenceTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  EVIDENCE_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/registry/listing-isolation.json")
  SOURCE_FILES = {
    "endpoint_sha256" => "app/controllers/concerns/hitch/mcp/endpoint.rb",
    "registry_sha256" => "app/models/hitch/mcp/registry.rb",
    "tool_sha256" => "app/models/hitch/mcp/tool.rb",
    "configuration_sha256" => "lib/hitch/mcp/configuration.rb",
    "engine_sha256" => "lib/hitch/engine.rb",
    "listing_test_sha256" => "test/integration/mcp_listing_test.rb",
    "request_support_sha256" => "test/support/mcp_listing_request_support.rb",
    "package_smoke_sha256" => "bin/package-smoke"
  }.freeze

  setup do
    @raw_evidence = EVIDENCE_PATH.read
    @evidence = JSON.parse(@raw_evidence)
    @source = @evidence.fetch("source")
  end

  test "evidence resolves to the immutable M3.3 implementation candidate" do
    assert_equal "hitch.m3.3-listing-isolation-evidence.v1", @evidence.fetch("schema")
    assert_equal "M3.3", @evidence.fetch("milestone")
    assert_equal "accepted_internal_checkpoint", @evidence.fetch("status")
    assert_equal "immutable_checkpoint", @source.fetch("state")
    assert_equal true, @source.fetch("worktree_clean_at_capture")

    commit = @source.fetch("commit")
    tree = @source.fetch("tree")
    assert_match(/\A[0-9a-f]{40}\z/, commit)
    assert_match(/\A[0-9a-f]{40}\z/, tree)
    assert_equal tree, git!("rev-parse", "#{commit}^{tree}").strip
    assert_predicate git_status("merge-base", "--is-ancestor", commit, "HEAD"), :success?
    assert_includes git!("show", "#{commit}:lib/hitch/version.rb"),
      %(VERSION = "#{@evidence.dig('artifact', 'version')}")

    packaged_paths = git!("ls-tree", "-r", "--name-only", commit).lines.map(&:strip)
    refute_includes packaged_paths, "app/models/hitch/mcp/slice_tool.rb"
  end

  test "source checksums bind resolver availability and filtered SDK construction" do
    SOURCE_FILES.each do |evidence_key, path|
      source = git!("show", "#{@source.fetch('commit')}:#{path}")
      assert_equal @evidence.dig("checksums", evidence_key), Digest::SHA256.hexdigest(source), path
    end

    contract = @evidence.fetch("request_contract")
    assert_equal 1, contract.fetch("scope_resolver_invocations_per_request")
    assert_equal false, contract.fetch("availability_default")
    assert_equal "filtered_tools_only", contract.fetch("sdk_construction")
    assert_equal "mcp_name_ascending", contract.fetch("listing_order")
    assert_equal false, contract.fetch("packaged_m2_slice_present")
    assert_equal "deferred_to_M5.2", contract.fetch("public_test_helpers")
  end

  test "evidence fixes registration availability and static scope precedence" do
    assert_equal %w[
      registration
      request_local_availability
      static_oauth_scope
      sdk_schema
      argument_policy
      host_execution
    ], @evidence.fetch("gate_precedence")

    cases = @evidence.fetch("visibility_cases").index_by { |entry| entry.fetch("case") }
    assert_equal %w[alpha.tool zeta.tool], cases.fetch("mcp_scope_listing").fetch("listed_names")
    assert_equal %w[admin.tool alpha.tool zeta.tool],
      cases.fetch("mcp_admin_scope_listing").fetch("listed_names")

    hidden = cases.fetch("unknown_and_unavailable_call")
    assert_equal 200, hidden.fetch("same_http_status")
    assert_equal(-32602, hidden.fetch("same_protocol_code"))
    assert_equal false, hidden.fetch("scope_challenge_present")

    step_up = cases.fetch("known_available_static_scope_insufficient")
    assert_equal 403, step_up.fetch("http_status")
    assert_equal "insufficient_scope", step_up.fetch("challenge_error")
    assert_equal %w[mcp admin], step_up.fetch("required_scope_set")
    assert_equal 0, step_up.fetch("sdk_dispatches")
  end

  test "failure and isolation evidence is fail closed and request local" do
    failures = @evidence.fetch("failure_cases")
    assert_equal "valid_opaque_scope", failures.fetch("nil_host_scope_result")
    assert_equal "captured_granted_scope_snapshot_unchanged",
      failures.fetch("resolver_mutates_access_token_scope_object")
    assert_match(/generic_-32603/, failures.fetch("raising_scope_resolver"))
    assert_match(/generic_-32603/, failures.fetch("raising_availability"))

    isolation = @evidence.fetch("isolation_cases")
    assert_equal 2, isolation.fetch("simulated_principals")
    assert_equal [ "concurrent.tool" ], isolation.fetch("alpha_visible_names")
    assert_equal [], isolation.fetch("beta_visible_names")
    assert_equal false, isolation.fetch("scope_or_availability_shared")
    assert_equal "waited_on_snapshot_lock", isolation.fetch("request_during_prepare")
    assert_equal false, isolation.fetch("stale_class_served")
  end

  test "acceptance spans SDK Rails and built-gem lanes without publication" do
    focused = @evidence.dig("acceptance", "focused_default")
    assert_equal [ 10, 76, 0, 0, 0 ],
      focused.values_at("runs", "assertions", "failures", "errors", "skips")

    profiles = @evidence.dig("acceptance", "rails_profiles")
    assert_equal %w[rails_7_2_sqlite rails_8_1_postgresql],
      profiles.map { |profile| profile.fetch("name") }
    assert profiles.all? { |profile| profile.values_at("failures", "errors", "skips") == [ 0, 0, 0 ] }

    sdk_lanes = @evidence.dig("acceptance", "sdk_lanes")
    assert_equal %w[min latest], sdk_lanes.map { |lane| lane.fetch("name") }
    assert sdk_lanes.all? { |lane| lane.fetch("resolved") == "1.1.0" }
    assert sdk_lanes.all? { |lane| lane.values_at("failures", "errors", "skips") == [ 0, 0, 0 ] }
    assert sdk_lanes.all? { |lane| lane.fetch("lock_sha256").match?(/\A[0-9a-f]{64}\z/) }

    package = @evidence.dig("acceptance", "package_smoke")
    assert_equal %w[rails_7_2_sqlite rails_8_1_postgresql], package.fetch("profiles")
    assert_includes package.fetch("result"), "without_publication"
    assert_equal false, package.fetch("container_digest_reproducibility_claimed")

    artifact = @evidence.fetch("artifact")
    assert_equal "internal_only", artifact.fetch("distribution")
    assert_equal true, artifact.fetch("checkpoint_sealed")
    assert_equal false, artifact.fetch("published")
    assert_equal false, artifact.fetch("rubygems_publication_performed")

    full_ci = @evidence.dig("acceptance", "full_ci")
    assert_equal @source.fetch("commit"), full_ci.fetch("source_commit")
    assert_equal "passed", full_ci.fetch("result")
    assert_equal "passed", full_ci.fetch("rails_7_2_sqlite")
    assert_equal "passed", full_ci.fetch("rails_8_1_postgresql")
  end

  test "evidence contains no credentials bodies or host records" do
    assert @evidence.fetch("sensitive_data").values.none?
    refute_match(/Bearer\s+[A-Za-z0-9_-]+/, @raw_evidence)
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
