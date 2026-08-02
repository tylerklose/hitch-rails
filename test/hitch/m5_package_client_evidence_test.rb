# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "open3"
require "time"
require "yaml"

class Hitch::M5PackageClientEvidenceTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  PACKAGE_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/package/disposable-apps.json")
  CLIENT_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/clients/automated-smokes.json")
  DECISION_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/release/pre4-publication-decision.json")
  DOWNLOADED_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/release/downloaded-pre4.json")

  setup do
    @package_raw = PACKAGE_PATH.read
    @client_raw = CLIENT_PATH.read
    @decision_raw = DECISION_PATH.read
    @package = JSON.parse(@package_raw, allow_duplicate_key: false)
    @clients = JSON.parse(@client_raw, allow_duplicate_key: false)
    @decision = JSON.parse(@decision_raw, allow_duplicate_key: false)
    @source = @decision.dig("checkpoint", "source")
  end

  test "evidence resolves to one immutable internal pre4 checkpoint" do
    assert_equal "hitch.m5.4-package-evidence.v1", @package.fetch("schema")
    assert_equal "hitch.m5.4-automated-client-evidence.v1", @clients.fetch("schema")
    assert_equal "hitch.m5.4-pre4-publication-decision.v1", @decision.fetch("schema")
    assert_equal [ "M5.4" ], [ @package, @clients, @decision ].map { |record| record.fetch("milestone") }.uniq
    [ @package, @clients ].each do |record|
      assert_equal "accepted_internal_checkpoint", record.fetch("status")
      assert_instance_of Time, Time.iso8601(record.fetch("verified_at"))
    end

    commit = @source.fetch("commit")
    assert_equal @source.fetch("tree"), git!("rev-parse", "#{commit}^{tree}").strip
    assert_predicate git_status("merge-base", "--is-ancestor", commit, "HEAD"), :success?
    assert_includes git!("show", "#{commit}:lib/hitch/version.rb"), 'VERSION = "0.2.0.pre.4"'
    assert_equal true, @source.fetch("clean_worktree")
    assert_equal @package.fetch("source").values_at("commit", "tree"),
      @clients.fetch("source").values_at("commit", "tree")
    assert_equal [ commit, @source.fetch("tree") ], @package.fetch("source").values_at("commit", "tree")
  end

  test "artifact identity and deferred publication agree everywhere" do
    artifacts = [ @package.fetch("artifact"), @clients.fetch("artifact"), @decision.dig("checkpoint", "artifact") ]
    assert_equal [ "hitch-rails-0.2.0.pre.4.gem" ], artifacts.map { |artifact| artifact.fetch("name") }.uniq
    assert_equal [ "e31a7636a4321026c4b10deaafddc1d396615622a5637b840285312c12870b31" ],
      artifacts.map { |artifact| artifact.fetch("sha256") }.uniq
    assert_equal "0.2.0.pre.4", @package.dig("artifact", "version")
    assert_equal 4, @package.dig("artifact", "deterministic_identical_builds")
    assert_equal "accepted_internal_artifact", @decision.dig("m6_input", "kind")
    assert_equal artifacts.first.fetch("sha256"), @decision.dig("m6_input", "sha256")

    assert_equal "deferred_to_final", @decision.fetch("decision")
    assert_equal [ false, false, false ], @decision.fetch("publication").values_at(
      "tag_created", "github_release_created", "rubygems_publication_performed"
    )
    assert_equal [ nil, nil, nil, nil ], @decision.fetch("publication").values_at(
      "repository_tag", "github_release", "rubygems_artifact", "rubygems_sha256"
    )
    assert_equal({ "status" => "not_applicable", "evidence_path" => nil },
      @decision.fetch("downloaded_pre4"))
    refute_predicate DOWNLOADED_PATH, :exist?
  end

  test "both packaged Rails profiles ran the documented golden path" do
    profiles = @package.fetch("profiles")
    assert_equal %w[rails_7_2_sqlite rails_8_1_postgresql], profiles.map { |profile| profile.fetch("name") }
    assert_equal [ [ "7.2.3.2", "sqlite3" ], [ "8.1.3.1", "postgresql" ] ],
      profiles.map { |profile| profile.values_at("rails", "adapter") }
    assert profiles.all? { |profile| profile.fetch("artifact_install") == "local_gem_repository" }
    assert profiles.all? { |profile| profile.fetch("rails_server") == "puma 8.0.2" }
    assert profiles.all? do |profile|
      profile.values_at(
        "generators", "migrations", "boot", "doctor", "discovery",
        "authorization_code", "token_exchange", "mcp_endpoint"
      ) == [
        "mcp_install_and_tool_ok", "ok", "ok", "no_actionable_failures", "ok",
        "ok", "ok", "authenticated_registry_discover_and_list_ok"
      ]
    end
    assert_includes @package.dig("acceptance", "shared_steps"),
      "bundle exec rails generate hitch:mcp:install"
    assert_equal [ "passed", true ], @package.fetch("cleanup").values_at(
      "postgresql_drop_command", "postgresql_catalog_absence_verified"
    )
  end

  test "the exhaustive client matrix covers every database SDK and OAuth class" do
    rows = @clients.fetch("scenarios")
    expected = %w[rails_7_2_sqlite rails_8_1_postgresql].product(
      %w[typescript python], %w[public confidential]
    ).sort
    actual = rows.map { |row| row.values_at("database", "sdk", "oauth_client") }.sort
    assert_equal expected, actual
    assert_equal (1..8).to_a, rows.map { |row| row.fetch("id") }
    assert rows.all? { |row| row.fetch("initial_scope") == "mcp" }
    assert rows.all? { |row| row.fetch("step_up_scope") == "mcp admin" }
    assert rows.all? { |row| row.fetch("result") == "discover_list_base_call_step_up_list_admin_call_ok" }
    assert_equal [ "none", "client_secret_basic" ],
      rows.map { |row| row.fetch("token_endpoint_auth_method") }.uniq.sort.reverse

    matrix = @clients.fetch("matrix")
    assert_equal [ 42, 3, 8, 8, 100.0 ], matrix.values_at(
      "seed", "strength", "exhaustive_count", "rows", "coverage_percent"
    )
    generated = source_json(matrix.fetch("scenarios_path"))
    assert_equal matrix.fetch("scenarios_sha256"), Digest::SHA256.hexdigest(source_bytes(matrix.fetch("scenarios_path")))
    generated_rows = generated.fetch("scenarios").map do |scenario|
      scenario.fetch("values").values_at("database", "sdk", "oauth_client")
    end
    assert_equal rows.map { |row| row.values_at("database", "sdk", "oauth_client") },
      generated_rows
  end

  test "client Redis and fixture pins match the accepted source" do
    lock = source_yaml("test/conformance/toolchain.lock.yml").fetch("automated_clients")
    clients = @clients.fetch("clients")
    assert_equal lock.dig("typescript", "version").to_s, clients.dig("typescript", "version")
    assert_equal lock.dig("typescript", "integrity"), clients.dig("typescript", "integrity")
    assert_equal lock.dig("typescript", "package_lock", "sha256"),
      clients.dig("typescript", "package_lock_sha256")
    assert_equal lock.dig("typescript", "fixture", "sha256"), clients.dig("typescript", "fixture_sha256")
    assert_equal lock.dig("python", "version").to_s, clients.dig("python", "version")
    assert_equal lock.dig("python", "sha256"), clients.dig("python", "wheel_sha256")
    assert_equal lock.dig("python", "requirements_lock", "sha256"),
      clients.dig("python", "requirements_sha256")
    assert_equal lock.dig("python", "fixture", "sha256"), clients.dig("python", "fixture_sha256")

    [
      [ "test/clients/typescript/package-lock.json", clients.dig("typescript", "package_lock_sha256") ],
      [ "test/clients/typescript/smoke.mjs", clients.dig("typescript", "fixture_sha256") ],
      [ "test/clients/python/requirements.lock", clients.dig("python", "requirements_sha256") ],
      [ "test/clients/python/smoke.py", clients.dig("python", "fixture_sha256") ]
    ].each do |path, expected|
      assert_equal expected, Digest::SHA256.hexdigest(source_bytes(path)), path
    end

    redis_lock = source_yaml("test/conformance/toolchain.lock.yml").fetch("redis")
    redis = @clients.fetch("redis")
    assert_equal redis_lock.values_at("image", "index_digest"), redis.values_at("image", "index_digest")
    assert_includes redis_lock.values_at("linux_arm64_digest", "linux_amd64_digest"), redis.fetch("platform_digest")
    assert_equal [ 15, "ephemeral_loopback_port", "disabled" ],
      redis.values_at("database", "network", "persistence")
  end

  test "evidence stays credential-free and keeps product clients outside authority" do
    assert_equal [ "not_approved", "not_run" ], @clients.fetch("approval").values_at(
      "product_model_clients", "product_model_client_status"
    )
    assert_equal [ "not_approved", "not_run", nil ], @decision.fetch("product_clients").values_at(
      "approval", "status", "evidence_path"
    )
    [ @package, @clients ].each do |record|
      assert_equal false, record.fetch("contains_credentials")
      assert_equal false, record.fetch("contains_request_bodies")
      assert_equal false, record.fetch("contains_raw_process_logs")
      assert_equal false, record.fetch("contains_temporary_paths")
    end
    [ @package_raw, @client_raw, @decision_raw ].each do |raw|
      refute_match(/Bearer\s+[A-Za-z0-9_-]+/, raw)
      refute_match(%r{/(?:private/)?(?:var|tmp)/}, raw)
    end
  end

  private

  def source_bytes(path)
    git!("show", "#{@source.fetch('commit')}:#{path}")
  end

  def source_json(path)
    JSON.parse(source_bytes(path), allow_duplicate_key: false)
  end

  def source_yaml(path)
    YAML.safe_load(source_bytes(path), permitted_classes: [], aliases: false)
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
