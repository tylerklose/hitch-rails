# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "open3"

class ConformanceEvidenceTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  SERVER_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/conformance/server-checks.json")
  AUTH_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/conformance/auth-extension.json")
  SOURCE_VERSION = "0.2.0.pre.1"
  UPSTREAM_COMMIT = "a9896553900a2ef61787b57adfcbbe936a8ab1f9"
  HARNESS_PATCH_SHA256 = "495975758b1f42f08c91b46f4151529348d2c8e82e376f672b27d7018faaca8b"
  AUTH_PATCH_SHA256 = "35403574632cf54ca6b133abfa5d52c91499972f17d55904890853ca130d2597"
  RUNNER_SHA256 = "fd6a0bcadaf0cdbd6305b1686758224cf0e71bcad550ab49d899ed8feb43179f"
  SCENARIOS = %w[
    server-stateless
    http-header-validation
    dns-rebinding-protection
    json-schema-2020-12
    tools-list
    tools-call-simple-text
    tools-call-error
  ].freeze
  EXPECTED_FAILURES = %w[
    server-stateless:sep-2575-server-rejects-undeclared-capability
    server-stateless:sep-2575-missing-capability-http-400
  ].freeze
  EXPECTED_SKIPS = %w[
    server-stateless:sep-2575-server-sends-subscription-ack
    server-stateless:sep-2575-server-tags-subscription-id
    server-stateless:sep-2575-server-honors-notification-filter
    server-stateless:sep-2575-server-sends-prompts-list-changed-on-subscription
    server-stateless:sep-2575-server-sends-tools-list-changed-on-subscription
  ].freeze
  FIXTURE_TOOLS = %w[
    test_simple_text
    test_error_handling
    json_schema_2020_12_tool
    test_streaming_elicitation
    test_logging_tool
  ].freeze

  setup do
    @server = JSON.parse(SERVER_PATH.read)
    @auth = JSON.parse(AUTH_PATH.read)
    @source = @server.dig("checkpoint", "source")
  end

  test "checkpoint evidence resolves to immutable sealed source" do
    assert_equal "hitch.m2.3-server-evidence.v1", @server.fetch("schema")
    assert_equal "M2.3", @server.fetch("milestone")
    assert_equal SOURCE_VERSION, @server.dig("checkpoint", "version")
    assert_equal "accepted_internal_checkpoint", @server.dig("checkpoint", "status")
    assert_equal "internal_only", @server.dig("checkpoint", "distribution")
    assert_equal false, @server.dig("checkpoint", "published")
    assert_equal true, @source.fetch("worktree_clean_at_run")
    assert_equal @source, @auth.fetch("source")

    commit = @source.fetch("commit")
    tree = @source.fetch("tree")
    assert_match(/\A[0-9a-f]{40}\z/, commit)
    assert_match(/\A[0-9a-f]{40}\z/, tree)
    assert_equal tree, git!("rev-parse", "#{commit}^{tree}").strip
    assert_predicate git_status("merge-base", "--is-ancestor", commit, "HEAD"), :success?
    assert_includes git!("show", "#{commit}:lib/hitch/version.rb"), %(VERSION = "#{SOURCE_VERSION}")
  end

  test "server evidence preserves the exact reviewed result boundary" do
    assert_equal UPSTREAM_COMMIT, @server.dig("upstream", "commit")
    assert_equal HARNESS_PATCH_SHA256, @server.dig("reviewed_extension", "patch_sha256")
    assert_equal RUNNER_SHA256, @server.dig("runner", "runner_sha256")
    assert_equal SCENARIOS, @server.dig("result", "scenarios")
    assert_equal FIXTURE_TOOLS, @server.dig("fixture", "fixture_tools")
    assert_equal [ "test_missing_capability" ], @server.dig("fixture", "runner_diagnostic_tools")
    assert_equal false, @server.dig("fixture", "production_registry_api_used")

    checks = @server.dig("result", "checks")
    counts = checks.map { |check| check.fetch("status").downcase }.tally
    assert_equal @server.dig("result", "counts"), %w[success failure warning skipped info].to_h { |key|
      [ key, counts.fetch(key, 0) ]
    }
    assert_equal({ "success" => 49, "failure" => 2, "warning" => 0, "skipped" => 5, "info" => 0 }, counts_with_zeros(counts))
    assert_equal EXPECTED_FAILURES, @server.dig("result", "expected_failures")
    assert_equal EXPECTED_FAILURES, entries_with_status(checks, "FAILURE")
    assert_equal EXPECTED_SKIPS, @server.dig("result", "capability_gated_skips")
    assert_equal EXPECTED_SKIPS, entries_with_status(checks, "SKIPPED")
    assert_equal [ "caching" ], @server.dig("result", "exclusions").keys
    assert_equal false, @server.fetch("contains_credentials")
    assert @server.fetch("secret_handling").values.all? { |value| value == true || value == false || value == "0600" }
  end

  test "sealed gem evidence is local only and passed both disposable profiles" do
    package = @server.dig("checkpoint", "package")
    assert_equal SOURCE_VERSION, package.fetch("artifact_version")
    assert_equal SOURCE_VERSION, package.fetch("target_checkpoint")
    assert_equal "checkpoint", package.fetch("phase")
    assert_equal true, package.fetch("checkpoint_sealed")
    assert_equal false, package.fetch("development")
    assert_equal "hitch-rails-#{SOURCE_VERSION}.gem", package.dig("artifact", "name")
    assert_match(/\A[0-9a-f]{64}\z/, package.dig("artifact", "sha256"))
    assert_equal 65, package.dig("artifact", "manifest_entries")
    assert package.dig("artifact", "checks").values.all? { |value| %w[ready absent match_checkout match_embedded_manifest matches_explicit_allowlist].include?(value) }

    apps = package.fetch("disposable_apps")
    assert_equal %w[rails_7_2_sqlite rails_8_1_postgresql], apps.map { |app| app.fetch("profile") }
    assert_equal %w[sqlite3 postgresql], apps.map { |app| app.fetch("adapter") }
    apps.each do |app|
      assert_equal SOURCE_VERSION, app.fetch("artifact_version")
      assert_equal "local_gem_repository", app.fetch("artifact_install")
      assert_equal "private_artifact_code_loaded", app.fetch("sdk_adapter")
      assert app.values_at("generator", "migrations", "boot", "discovery", "authorization_code", "token_exchange")
        .all? { |value| value == "ok" }
      assert_equal "authenticated_discover_and_call_ok", app.fetch("mcp_endpoint")
    end
    assert @server.dig("checkpoint", "full_ci", "gates").values.all? { |value| value == "green" }
  end

  test "authorization evidence keeps official and reviewed extension claims separate" do
    assert_equal "hitch.m2.3-auth-extension-evidence.v1", @auth.fetch("schema")
    assert_equal UPSTREAM_COMMIT, @auth.dig("upstream", "commit")
    assert_equal "official_unmodified_authorization_metadata", @auth.dig("classification", "metadata")
    assert_equal "reviewed_resource_indicator_extension", @auth.dig("classification", "grants")

    official = @auth.fetch("official_unmodified_authorization_metadata")
    assert_equal 2, official.length
    assert official.all? { |check| check.fetch("status") == "SUCCESS" }

    extension = @auth.fetch("reviewed_resource_indicator_extension")
    assert_equal AUTH_PATCH_SHA256, extension.dig("patch", "sha256")
    assert_equal HARNESS_PATCH_SHA256, extension.dig("combined_server_harness", "sha256")
    assert_equal RUNNER_SHA256, extension.dig("combined_server_harness", "runner_sha256")
    %w[public confidential_client_secret_basic].each do |profile|
      value = extension.fetch(profile)
      assert_equal 3, value.fetch("checks").length
      assert value.fetch("checks").all? { |check| check.fetch("status") == "SUCCESS" }
      assert_equal [ true, true, "approved", true, false ], value.fetch("operator").values_at(
        "consent_html_verified", "csrf_present", "approval", "callback_delivered",
        "credential_values_in_operator_output"
      )
    end
    assert_equal false, @auth.fetch("contains_credentials")
    refute_includes JSON.generate(@auth), "127.0.0.1"
    assert_includes @auth.fetch("raw_artifact"), "destroyed"
    assert_includes @auth.fetch("raw_artifact"), "never uploaded"
  end

  test "checked patch bytes match the sealed source" do
    commit = @source.fetch("commit")
    assert_equal HARNESS_PATCH_SHA256,
      Digest::SHA256.hexdigest(git!("show", "#{commit}:test/conformance/harness.patch"))
    assert_equal AUTH_PATCH_SHA256,
      Digest::SHA256.hexdigest(git!("show", "#{commit}:docs/evidence/0.1.0/auth/resource-aware-grants.patch"))
  end

  private

  def entries_with_status(checks, status)
    checks.filter_map do |check|
      "#{check.fetch('scenario')}:#{check.fetch('id')}" if check.fetch("status") == status
    end.uniq
  end

  def counts_with_zeros(counts)
    %w[success failure warning skipped info].to_h { |key| [ key, counts.fetch(key, 0) ] }
  end

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
