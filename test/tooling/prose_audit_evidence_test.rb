# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "open3"
require "time"

class ProseAuditEvidenceTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  EVIDENCE_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/operator/prose-audit.json")
  SOURCE_FILES = {
    "prose_audit_sha256" => "bin/prose-audit",
    "prose_audit_test_sha256" => "test/tooling/prose_audit_test.rb",
    "readme_sha256" => "README.md",
    "changelog_sha256" => "CHANGELOG.md",
    "security_sha256" => "SECURITY.md",
    "doctor_guide_sha256" => "docs/operator/doctor.md",
    "redis_guide_sha256" => "docs/operator/redis.md",
    "upgrade_guide_sha256" => "docs/upgrading/0.2.0.md",
    "removal_guide_sha256" => "docs/removing.md",
    "public_api_sha256" => "docs/public_api/0.2.0.md",
    "work_packet_sha256" => "docs/work_packets/M5.3.md"
  }.freeze

  setup do
    @raw_evidence = EVIDENCE_PATH.read
    @evidence = JSON.parse(@raw_evidence)
    @source = @evidence.fetch("source")
  end

  test "evidence resolves to the immutable unpublished M5.3 prose surface" do
    assert_equal "hitch.m5.3-prose-audit-evidence.v1", @evidence.fetch("schema")
    assert_equal "M5.3", @evidence.fetch("milestone")
    assert_equal "verified_internal_development", @evidence.fetch("status")
    assert_instance_of Time, Time.iso8601(@evidence.fetch("verified_at"))
    assert_equal "immutable_implementation_candidate", @source.fetch("state")
    assert_equal true, @source.fetch("worktree_clean_before_acceptance")
    assert_equal true, @source.fetch("acceptance_commands_ran_against_source_commit")

    commit = @source.fetch("commit")
    assert_equal @source.fetch("tree"), git!("rev-parse", "#{commit}^{tree}").strip
    assert_equal @source.fetch("predecessor_commit"), git!("rev-parse", "#{commit}^").strip
    assert_predicate git_status("merge-base", "--is-ancestor", commit, "HEAD"), :success?

    artifact = @evidence.fetch("artifact")
    assert_equal [ "0.2.0.pre.4.dev", "0.2.0.pre.4" ],
      artifact.values_at("version", "target_checkpoint")
    assert_equal [ false, false, false, false ], artifact.values_at(
      "published",
      "tag_created",
      "github_release_created",
      "rubygems_publication_performed"
    )
    assert_equal "deferred_until_M5.4_or_final_0.2.0", artifact.fetch("publication_decision")
  end

  test "checksums bind the audit and maintained prose to the implementation commit" do
    SOURCE_FILES.each do |evidence_key, source_file|
      source = git!("show", "#{@source.fetch('commit')}:#{source_file}")
      assert_equal @evidence.dig("checksums", evidence_key), Digest::SHA256.hexdigest(source), source_file
    end
  end

  test "pattern inventory and repository search boundaries match the executable audit" do
    source = git!("show", "#{@source.fetch('commit')}:bin/prose-audit")
    main_body = source.match(/patterns = \{(?<body>.*?)\n\}\.freeze/m)[:body]
    release_body = source.match(/release_patterns = \{(?<body>.*?)\n\}\.freeze/m)[:body]
    source_patterns = [ main_body, release_body ].flat_map do |body|
      body.scan(/^  "([^"]+)" => /).flatten
    end
    assert_equal @evidence.fetch("patterns"), source_patterns

    audit = @evidence.fetch("audit")
    assert_equal [ "bin/prose-audit", "--root PATH", 31, 301, 301, 3, 0 ], audit.values_at(
      "command",
      "root_override",
      "pattern_count",
      "searched_files",
      "release_policy_searched_files",
      "allowlisted_historical_fixtures",
      "stale_matches"
    )
    audit.fetch("included_extensions").each { |extension| assert_includes source, extension }
    audit.fetch("ignored_prefixes").each { |prefix| assert_includes source, prefix }
    audit.fetch("ignored_files").each { |path| assert_includes source, path }
    assert_includes source, 'relative.end_with?("_scenarios.json")'
    assert_equal [ true, true ], audit.values_at(
      "extensionless_bin_files_included",
      "generated_scenario_json_excluded"
    )
  end

  test "historical allowlist is exact and unused entries fail closed" do
    entries = @evidence.fetch("historical_allowlist")
    assert_equal [
      [ "PostgreSQL-only support claim", "docs/work_packets/M0.5.md" ],
      [ "PostgreSQL-only code consumption", "ROADMAP.md" ],
      [ "PostgreSQL-only code consumption", "docs/work_packets/M0.3b.md" ]
    ], entries.map { |entry| entry.values_at("pattern", "path") }

    source = git!("show", "#{@source.fetch('commit')}:bin/prose-audit")
    entries.each { |entry| assert_includes source, entry.fetch("path").gsub(".", "\\.") }
    assert_includes source, "unused historical allowlist"
    assert_includes source, "expected_allowlist - used_allowlist"
  end

  test "mutation and acceptance results prove stale mechanisms fail" do
    mutation = @evidence.fetch("mutation_suite")
    assert_equal [
      "bin/ci-test test/tooling/prose_audit_test.rb",
      @source.fetch("commit"),
      3,
      25,
      0,
      0,
      0,
      true
    ], mutation.values_at(
      "command",
      "source_commit",
      "runs",
      "assertions",
      "failures",
      "errors",
      "skips",
      "historical_evidence_exclusion_verified"
    )
    assert_equal %w[
      tool_generator_auto_registration
      production_memory_rate_store
      doctor_repair_mode
      premature_pre4_publication
    ], mutation.fetch("mutations_refused")

    audit = @evidence.dig("acceptance", "prose_audit")
    assert_equal [ "bin/prose-audit", @source.fetch("commit"), 31, 301, 3, 0 ], audit.values_at(
      "command",
      "source_commit",
      "patterns",
      "searched_files",
      "allowlisted_historical_fixtures",
      "stale_matches"
    )
    combined = @evidence.dig("acceptance", "combined_tooling")
    assert_equal [ 6, 42, 0, 0, 0 ], combined.values_at(
      "runs", "assertions", "failures", "errors", "skips"
    )
    assert_equal false, @evidence.fetch("contains_raw_process_logs")
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
