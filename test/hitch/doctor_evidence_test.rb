# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "open3"
require "time"

class Hitch::DoctorEvidenceTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  EVIDENCE_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/operator/doctor-snapshots.json")
  SOURCE_FILES = {
    "doctor_sha256" => "lib/hitch/doctor.rb",
    "engine_sha256" => "lib/hitch/engine.rb",
    "task_sha256" => "lib/tasks/hitch.rake",
    "doctor_test_sha256" => "test/hitch/doctor_test.rb",
    "doctor_task_test_sha256" => "test/hitch/doctor_task_test.rb",
    "lattice_schema_sha256" => "test/lattice/doctor.json",
    "lattice_scenarios_sha256" => "test/lattice/doctor_scenarios.json",
    "doctor_runner_sha256" => "bin/doctor-fixtures",
    "dispatcher_test_sha256" => "test/tooling/doctor_fixtures_dispatch_test.rb",
    "doctor_guide_sha256" => "docs/operator/doctor.md",
    "redis_guide_sha256" => "docs/operator/redis.md",
    "upgrade_guide_sha256" => "docs/upgrading/0.2.0.md",
    "removal_guide_sha256" => "docs/removing.md",
    "public_api_sha256" => "docs/public_api/0.2.0.md",
    "package_smoke_sha256" => "bin/package-smoke",
    "gemspec_sha256" => "hitch-rails.gemspec",
    "work_packet_sha256" => "docs/work_packets/M5.3.md"
  }.freeze

  setup do
    @raw_evidence = EVIDENCE_PATH.read
    @evidence = JSON.parse(@raw_evidence)
    @source = @evidence.fetch("source")
  end

  test "evidence resolves to the immutable unpublished M5.3 implementation" do
    assert_equal "hitch.m5.3-doctor-snapshots-evidence.v1", @evidence.fetch("schema")
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
    assert_includes git!("show", "#{commit}:lib/hitch/version.rb"), 'VERSION = "0.2.0.pre.4.dev"'

    artifact = @evidence.fetch("artifact")
    assert_equal [ "0.2.0.pre.4.dev", "0.2.0.pre.4", "public_optional" ],
      artifact.values_at("version", "target_checkpoint", "distribution")
    assert_equal [ false, false, false, false, false, false ], artifact.values_at(
      "checkpoint_sealed",
      "public_eligible",
      "published",
      "tag_created",
      "github_release_created",
      "rubygems_publication_performed"
    )
    assert_equal "deferred_until_M5.4_or_final_0.2.0", artifact.fetch("publication_decision")
  end

  test "checksums bind doctor runtime fixtures package and operator docs to the implementation commit" do
    SOURCE_FILES.each do |evidence_key, source_file|
      source = git!("show", "#{@source.fetch('commit')}:#{source_file}")
      assert_equal @evidence.dig("checksums", evidence_key), Digest::SHA256.hexdigest(source), source_file
    end
  end

  test "public contract and Lattice evidence cover every stable diagnostic category" do
    contract = @evidence.fetch("public_contract")
    assert_equal "hitch.doctor.v1", contract.fetch("schema")
    assert_equal %w[human json], contract.fetch("formats")
    assert_equal %w[ok warning error], contract.fetch("overall_statuses")
    assert_equal %w[pass warn fail skip], contract.fetch("check_statuses")
    assert_equal [ 1, 0, true, false ], contract.values_at(
      "failure_exit_status",
      "warning_exit_status",
      "renders_all_checks_before_exit",
      "repair_mode"
    )
    assert_equal %w[
      versions
      configuration
      resource_discovery
      route_order
      migrations
      registry
      hosts
      origins
      redis_connectivity
      redis_atomicity_expiry
      package
      legacy_endpoint
    ], contract.fetch("check_ids")

    schema = source_json("test/lattice/doctor.json")
    scenarios = source_json("test/lattice/doctor_scenarios.json")
    lattice = @evidence.fetch("lattice")
    assert_equal lattice.fetch("model"), schema.fetch("model_name")
    assert_equal lattice.fetch("parameters"), schema.fetch("parameters").length
    assert_equal lattice.fetch("forced_constraints"),
      schema.fetch("constraints").count { |constraint| constraint.fetch("type") == "forced" }
    assert_equal [ 42, 2, 27, 124_416, "4608x", "100.0%" ], [
      scenarios.dig("meta", "seed"),
      scenarios.dig("meta", "strength"),
      scenarios.dig("meta", "test_count"),
      scenarios.dig("meta", "exhaustive_count"),
      scenarios.dig("meta", "reduction"),
      scenarios.dig("meta", "coverage")
    ]
    assert_equal (1..27).to_a, scenarios.fetch("scenarios").map { |scenario| scenario.fetch("id") }
    assert_equal 20, @evidence.fetch("stable_outcomes_covered").length
    assert_equal [ true, true, true ], lattice.values_at(
      "healthy_full_runtime_forced",
      "healthy_auth_only_forced",
      "every_actionable_category_forced"
    )
  end

  test "redacted healthy snapshots pin full-runtime and auth-only skip semantics" do
    snapshots = @evidence.fetch("redacted_snapshots")
    full = snapshots.fetch("healthy_full_runtime")
    assert_equal [ "ok", false, "Hitch doctor v1: OK", "Summary: pass=12 warn=0 fail=0 skip=0" ],
      full.values_at("overall", "failure", "human_header", "human_summary")
    assert_equal({ "pass" => 12, "warn" => 0, "fail" => 0, "skip" => 0 }, full.fetch("counts"))
    assert_equal 12, full.fetch("checks").length
    assert full.fetch("checks").all? { |check| check.include?(":pass:") }

    auth_only = snapshots.fetch("healthy_auth_only")
    assert_equal({ "pass" => 8, "warn" => 0, "fail" => 0, "skip" => 4 }, auth_only.fetch("counts"))
    skipped = auth_only.fetch("checks").grep(/:skip:runtime_disabled\z/)
    assert_equal 4, skipped.length
    assert_equal %w[route_order registry redis_connectivity redis_atomicity_expiry],
      skipped.map { |check| check.split(":").first }
  end

  test "Redis package boot redaction and acceptance claims remain exact" do
    redis = @evidence.fetch("redis_probe")
    assert_equal [ true, "hitch:doctor:v1", 32, false, true, [ 1, 2 ], 5000, true, true, true, true ],
      redis.values_at(
        "dedicated_connection",
        "namespace_prefix",
        "random_suffix_hex_characters",
        "application_quota_namespace_touched",
        "single_lua_operation",
        "expected_increment_sequence",
        "expiry_ms",
        "cleanup_in_script",
        "cleanup_in_ensure",
        "connection_closed_in_ensure",
        "target_redacted"
      )
    doctor_source = git!("show", "#{@source.fetch('commit')}:lib/hitch/doctor.rb")
    assert_includes doctor_source, 'key = "hitch:doctor:v1:#{SecureRandom.hex(16)}"'
    assert_includes doctor_source, 'redis.call("PEXPIRE", KEYS[1], ARGV[1])'
    assert_includes doctor_source, "client&.del(key)"
    assert_includes doctor_source, "client&.close"

    boot = @evidence.fetch("boot_and_package")
    assert_equal [ true, false, true, true, true ], boot.values_at(
      "doctor_only_boot_bypass",
      "mixed_task_boot_bypass",
      "production_dcr_shared_store_validated_by_doctor",
      "installed_gemspec_empty_file_list_falls_back_to_disk",
      "package_forbidden_test_and_evidence_paths"
    )

    fixtures = @evidence.dig("acceptance", "doctor_fixtures")
    assert_equal [ "bin/doctor-fixtures", @source.fetch("commit"), 27, 31, 555, 0, 0, 0 ],
      fixtures.values_at(
        "command", "source_commit", "lattice_rows", "runs", "assertions",
        "failures", "errors", "skips"
      )
    package = @evidence.dig("acceptance", "package_smoke")
    assert_equal @source.fetch("tree"), package.fetch("source_tree")
    assert_equal "6b411eed00a4bd29cbea02484673a7d77e95362901d74a6e38c7e3567bad4f97",
      package.fetch("gem_sha256")
    assert_equal %w[rails_7_2_sqlite rails_8_1_postgresql],
      package.fetch("profiles").map { |profile| profile.fetch("name") }
    assert package.fetch("profiles").all? { |profile| profile.fetch("doctor") == "no_actionable_failures" }
    assert_equal false, package.fetch("published")

    assert @evidence.fetch("redaction").values.all? { |value| value == false }
    refute_match(/Bearer\s+[A-Za-z0-9_-]+/, @raw_evidence)
    refute_includes @raw_evidence, "redis-super-secret"
    refute_includes @raw_evidence, "credential-secret"
    refute_includes @raw_evidence, "internal-secret"
  end

  private

  def source_json(path)
    JSON.parse(git!("show", "#{@source.fetch('commit')}:#{path}"))
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
