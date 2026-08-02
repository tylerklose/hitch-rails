# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "open3"
require "time"
require "yaml"

class Hitch::MCP::ContractMutationEvidenceTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  EVIDENCE_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/quality/m4-contract-mutation.json")
  SOURCE_FILES = {
    "toolchain_lock_sha256" => "test/conformance/toolchain.lock.yml",
    "lattice_schema_sha256" => "test/lattice/mcp_tool_authorization.json",
    "lattice_scenarios_sha256" => "test/lattice/mcp_tool_authorization_scenarios.json",
    "lattice_oracles_sha256" => "test/contracts/mcp_tool_authorization_oracles.yml",
    "forced_suites_sha256" => "test/contracts/mcp_m4_forced_suites.yml",
    "mutation_subjects_sha256" => "test/contracts/mcp_m4_mutation_subjects.yml",
    "lattice_test_sha256" => "test/integration/mcp_tool_authorization_lattice_test.rb",
    "mutation_coverage_sha256" => "test/mutation/mcp_coverage_test.rb",
    "contract_runner_sha256" => "bin/contract",
    "mutation_runner_sha256" => "bin/mutation-mcp",
    "generator_dispatcher_sha256" => "bin/ci-generators",
    "generator_dispatch_test_sha256" => "test/tooling/ci_generators_dispatch_test.rb",
    "gemfile_sha256" => "Gemfile",
    "work_packet_sha256" => "docs/work_packets/M4.5.md"
  }.freeze

  setup do
    @raw_evidence = EVIDENCE_PATH.read
    @evidence = JSON.parse(@raw_evidence)
    @source = @evidence.fetch("source")
  end

  test "evidence resolves to the immutable M4.5 implementation candidate" do
    assert_equal "hitch.m4.5-contract-mutation-evidence.v1", @evidence.fetch("schema")
    assert_equal "M4.5", @evidence.fetch("milestone")
    assert_equal "accepted_internal_quality_candidate", @evidence.fetch("status")
    assert_instance_of Time, Time.iso8601(@evidence.fetch("verified_at"))
    assert_equal "immutable_implementation_candidate", @source.fetch("state")
    assert_equal true, @source.fetch("acceptance_commands_ran_against_source_commit")

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
    assert artifact.values_at(
      "published",
      "tag_created",
      "github_release_created",
      "rubygems_publication_performed"
    ).none?
  end

  test "checksums bind the exact contract mutation and dispatcher artifacts" do
    SOURCE_FILES.each do |evidence_key, source_file|
      source = git!("show", "#{@source.fetch('commit')}:#{source_file}")
      assert_equal @evidence.dig("checksums", evidence_key), Digest::SHA256.hexdigest(source), source_file
    end
  end

  test "authorization scenarios preserve all twelve ordered terminal paths" do
    lattice = @evidence.fetch("authorization_lattice")
    assert_equal "hitch_mcp_tool_authorization", lattice.fetch("model")
    assert_equal [ 42, 8, 12 ], lattice.values_at("seed", "exhaustive_strength", "scenario_count")
    assert lattice.values_at(
      "default_generation_matched_checked_artifact",
      "strength_8_generation_matched_checked_artifact",
      "checked_artifact_unchanged_during_contract_run"
    ).all?

    scenarios = lattice.fetch("scenarios")
    assert_equal (1..12).to_a, scenarios.map { |scenario| scenario.fetch("id") }
    assert_equal %w[
      success token_missing token_expired_or_revoked token_wrong_audience
      authenticated_admission_reject tool_unregistered tool_unavailable
      static_scope_insufficient input_schema_invalid argument_policy_deny
      host_safe_error host_raises
    ], scenarios.map { |scenario| scenario.fetch("terminal") }
    assert_equal %w[expired revoked], scenarios.fetch(2).fetch("concrete_variants")
  end

  test "every forced M4 boundary suite passed while generator collisions remain deferred" do
    forced = @evidence.fetch("forced_suites")
    manifest = source_yaml("test/contracts/mcp_m4_forced_suites.yml")
    outcomes = forced.fetch("outcomes")

    assert_equal 13, forced.fetch("manifest_count")
    assert_equal manifest.fetch("required_boundaries"), forced.fetch("required_boundaries")
    assert_equal manifest.fetch("suites").map { |suite| suite.slice("id", "path") },
      outcomes.map { |outcome| outcome.slice("id", "path") }
    assert outcomes.all? { |outcome| outcome.fetch("status") == "passed" }

    deferred = forced.fetch("deferred_generator_boundaries")
    assert_equal %w[generator_install_collisions generator_tool_collisions],
      deferred.map { |boundary| boundary.fetch("id") }
    assert deferred.none? { |boundary| boundary.fetch("accepted") }
    assert deferred.all? { |boundary| boundary.fetch("dispatcher_exit_status") == 69 }
  end

  test "mutation evidence covers the exact manifest with no survivor or timeout" do
    mutation = @evidence.fetch("mutation")
    manifest = source_yaml("test/contracts/mcp_m4_mutation_subjects.yml")
    subjects = mutation.fetch("subjects")

    assert_equal [ "mutant", "0.16.3", "mutant-minitest", "0.16.3", "3.4.7" ],
      mutation.values_at("runner", "runner_version", "integration", "integration_version", "ruby_version")
    assert_equal [ 15, 13, 818, 818, 0, 0, 100.0 ], mutation.values_at(
      "subject_count",
      "domain_count",
      "evaluated_results",
      "criteria_satisfied_results",
      "survivors",
      "timeouts",
      "coverage_percent"
    )
    assert_equal manifest.fetch("subjects"), subjects.map { |subject| subject.slice("domain", "expression") }
    assert_equal manifest.fetch("required_domains"), subjects.map { |subject| subject.fetch("domain") }.uniq
    assert_equal 818, subjects.sum { |subject| subject.fetch("evaluated_results") }
    assert subjects.all? do |subject|
      subject.fetch("criteria_satisfied_results") == subject.fetch("evaluated_results") &&
        subject.values_at("survivors", "timeouts") == [ 0, 0 ]
    end

    raw = mutation.fetch("raw_session_artifact")
    assert_equal false, raw.fetch("committed")
    assert_equal "destroyed_after_redacted_summary", raw.fetch("retention")
  end

  test "acceptance records every M4.5 command without claiming checkpoint CI" do
    contract = @evidence.dig("acceptance", "contract")
    assert_equal "bin/contract", contract.fetch("command")
    assert_equal [ 12, 13, 121, 3657, 0, 0, 0 ], contract.values_at(
      "scenario_rows",
      "forced_suites",
      "runs",
      "assertions",
      "failures",
      "errors",
      "skips"
    )

    mutation = @evidence.dig("acceptance", "mutation")
    assert_equal "bin/mutation-mcp", mutation.fetch("command")
    assert_equal [ 15, 13, 818, 818, 0, 0 ], mutation.values_at(
      "subjects",
      "domains",
      "evaluated_results",
      "criteria_satisfied_results",
      "survivors",
      "timeouts"
    )

    lanes = @evidence.dig("acceptance", "sdk_lanes")
    assert_equal %w[min latest], lanes.map { |lane| lane.fetch("name") }
    assert_equal [ "bin/ci-sdk min", "bin/ci-sdk latest" ], lanes.map { |lane| lane.fetch("command") }
    assert lanes.all? { |lane| lane.fetch("resolved") == "1.1.0" }
    assert_equal [ 21, 21 ], lanes.map { |lane| lane.fetch("runs") }
    assert_equal [ 350, 349 ], lanes.map { |lane| lane.fetch("assertions") }
    assert lanes.all? { |lane| lane.values_at("failures", "errors", "skips") == [ 0, 0, 0 ] }

    assert_equal "deferred_to_sealed_checkpoint_acceptance", @evidence.dig("acceptance", "full_ci")
    assert_equal "deferred_to_sealed_checkpoint_acceptance", @evidence.dig("acceptance", "package_smoke")
  end

  test "evidence contains no credentials request bodies host records or raw process logs" do
    assert_equal false, @evidence.fetch("contains_credentials")
    assert_equal false, @evidence.fetch("contains_request_bodies")
    assert_equal false, @evidence.fetch("contains_host_records")
    assert_equal false, @evidence.fetch("contains_raw_mutation_logs")
    refute_match(/Bearer\s+[A-Za-z0-9_-]+/, @raw_evidence)
    refute_match(/mutation_(?:source|diff|identification)|process_status|isolation_result/, @raw_evidence)
  end

  private

  def source_yaml(source_file)
    YAML.safe_load(
      git!("show", "#{@source.fetch('commit')}:#{source_file}"),
      permitted_classes: [],
      aliases: false
    )
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
