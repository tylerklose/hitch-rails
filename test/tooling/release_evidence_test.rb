# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"
require_relative "../../tooling/release_artifact"
load File.expand_path("../../bin/verify-release-evidence", __dir__)

class ReleaseEvidenceTest < ActiveSupport::TestCase
  VerificationStatus = Data.define(:passed) do
    def success? = passed
    def exitstatus = passed ? 0 : 1
  end
  private_constant :VerificationStatus
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  VERIFIER = REPOSITORY_ROOT.join("bin/verify-release-evidence").to_s
  CONTRACT_PATH = "docs/contracts/release_evidence.yml"
  INDEX_PATH = "docs/evidence/0.2.0/index.json"
  DECISION_PATH = "docs/evidence/0.2.0/release/pre4-publication-decision.json"
  SCENARIOS_PATH = REPOSITORY_ROOT.join("test/lattice/release_evidence_scenarios.json")

  setup do
    reset_fixture
  end

  teardown do
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
  end

  test "accepts the complete current index while future evidence remains absent" do
    stdout, stderr, status = run_verifier

    assert_predicate status, :success?, stderr
    assert_includes stdout, "23 accepted, 9 pending"
    assert_includes stdout, "M6-M8 remain fail-closed"
  end

  test "CLI authenticates a real source-bound release artifact" do
    @real_release_artifacts = true
    accept("copied_lineage", m6_evidence)

    stdout, stderr, status = run_cli_verifier("--through", "M6")

    assert_predicate status, :success?, stderr
    assert_includes stdout, "through M6"

    evidence = m6_evidence
    evidence["checkpoint"]["sha256"] = "f" * 64
    accept("copied_lineage", evidence)
    _stdout, stderr, status = run_cli_verifier("--through", "M6")

    assert_not status.success?
    assert_includes stderr, "artifact proof failed"
  end

  test "fails closed for every unaccepted milestone and the final release" do
    _stdout, stderr, status = run_verifier("--through", "M6")
    assert_not status.success?
    assert_includes stderr, "adoption/copied-lineage.json"

    _stdout, stderr, status = run_verifier("--preflight", "0.2.0")
    assert_not status.success?
    assert_includes stderr, "adoption/copied-lineage.json"
    assert_includes stderr, "adoption/independent.json"
    assert_includes stderr, "clients/product-smokes.json"
    assert_includes stderr, "release/final-check.json"
    assert_includes stderr, "release/final-publication-authority.json"

    _stdout, stderr, status = run_verifier("--complete", "0.2.0")
    assert_not status.success?
    assert_includes stderr, "release/downloaded-gem.json"

    _stdout, stderr, status = run_verifier("--through", "M8")
    assert_not status.success?
    assert_includes stderr, "release/downloaded-gem.json"
  end

  test "enforces the recorded decision to defer the public prerelease train" do
    %w[0.2.0.pre.4 0.2.0.rc1 0.2.0.rc2].each do |version|
      _stdout, stderr, status = run_verifier("--preflight", version)

      assert_not status.success?
      assert_includes stderr, "deferred public RubyGems publication until 0.2.0"
      assert_includes stderr, "#{version} is internal-only"
    end
  end

  test "rejects reopening the resolved prerelease publication branch" do
    decision = JSON.parse(File.binread(File.join(@root, DECISION_PATH)))
    decision["decision"] = "published_pre4"
    decision["m6_input"]["kind"] = "published_pre4"
    write_json(DECISION_PATH, decision)
    record_for("pre4_publication_decision")["sha256"] =
      Digest::SHA256.file(File.join(@root, DECISION_PATH)).hexdigest
    save_index

    _stdout, stderr, status = run_verifier

    assert_not status.success?
    assert_includes stderr, "must remain the resolved deferred_to_final decision"
  end

  test "rejects contract drift duplicate JSON unindexed files and premature pending files" do
    File.write(File.join(@root, CONTRACT_PATH), "#{File.read(File.join(@root, CONTRACT_PATH))}\n")
    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "contract SHA-256 drifted"

    reset_fixture
    index_path = File.join(@root, INDEX_PATH)
    File.write(index_path, File.read(index_path).sub(
      '"release": "0.2.0"',
      '"release": "0.2.0", "release": "0.2.1"'
    ))
    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, 'duplicate key "release"'

    reset_fixture
    write_json("docs/evidence/0.2.0/unindexed.json", { "status" => "claimed" })
    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "release evidence files are not indexed"

    reset_fixture
    write_json(record_for("copied_lineage").fetch("path"), m6_evidence)
    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "must be absent until it is accepted"
  end

  test "rejects accepted evidence digest drift and an incomplete index" do
    path = record_for("automated_client_smokes").fetch("path")
    File.write(File.join(@root, path), "#{File.read(File.join(@root, path))} ")
    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "#{path} SHA-256 drifted"

    reset_fixture
    index.fetch("records").reject! { |record| record["kind"] == "copied_lineage" }
    save_index
    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "missing future record copied_lineage"

    reset_fixture
    record = record_for("auth_conformance")
    FileUtils.rm(File.join(@root, record.fetch("path")), force: true)
    index.fetch("records").delete(record)
    save_index
    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "missing accepted record auth_conformance"
  end

  test "Lattice exhaustively proves all valid release and milestone combinations" do
    scenarios = JSON.parse(SCENARIOS_PATH.read).fetch("scenarios")
    assert_equal 60, scenarios.length

    scenarios.each do |scenario|
      reset_fixture
      # M4.3 was reopened by the admission-store erratum. It is a milestone
      # prerequisite, not a release-lifecycle gate, so every modeled row starts
      # from it re-accepted; the Lattice covers M6-M8 ordering only.
      accept("rate_limit_cross_process", rate_limit_cross_process_evidence)
      values = scenario.fetch("values")
      accept("copied_lineage", m6_evidence) if values.fetch("m6_evidence") == "accepted"
      accept("independent", m7_evidence) if values.fetch("m7_evidence") == "accepted"
      accept("product_clients", product_client_evidence) if values.fetch("product_client_evidence") == "accepted"
      accept("hosted_matrix", hosted_matrix_evidence) if values.fetch("hosted_matrix_evidence") == "accepted"
      accept("final_local_gates", final_local_gates_evidence) if values.fetch("final_local_gates_evidence") == "accepted"
      accept("final_check", final_check_evidence) if values.fetch("final_check_evidence") == "accepted"
      accept("publication_authority", publication_authority_evidence) if values.fetch("publication_authority") == "accepted"
      accept("downloaded_gem", downloaded_gem_evidence) if values.fetch("downloaded_gem_evidence") == "accepted"

      gate = values.fetch("requested_gate")
      arguments = case gate
      when "pre4_preflight" then [ "--preflight", "0.2.0.pre.4" ]
      when "rc1_preflight" then [ "--preflight", "0.2.0.rc1" ]
      when "rc2_preflight" then [ "--preflight", "0.2.0.rc2" ]
      when "final_readiness" then [ "--ready-for-authority", "0.2.0" ]
      when "final_preflight" then [ "--preflight", "0.2.0" ]
      when "final_complete" then [ "--complete", "0.2.0" ]
      end
      _stdout, stderr, status = run_verifier(*arguments)
      expected = case gate
      when "pre4_preflight", "rc1_preflight", "rc2_preflight" then false
      when "final_readiness"
        values.fetch("final_check_evidence") == "accepted" &&
          values.fetch("publication_authority") == "absent"
      when "final_preflight" then values.fetch("publication_authority") == "accepted"
      when "final_complete" then values.fetch("downloaded_gem_evidence") == "accepted"
      end
      assert_equal expected, status.success?, "scenario #{scenario.fetch('id')}: #{stderr}"
    end
  end

  test "rejects copied-lineage performance exceptions without explicit acceptance" do
    evidence = m6_evidence
    call_result = evidence["benchmark"]["operations"].find { |operation| operation["name"] == "tools/call" }
    call_result["new_runs"].each { |run| run["p95_ms"] = 120.0 }
    call_result["new_median_p95_ms"] = 120.0
    call_result["regression_percent"] = 20.0
    accept("copied_lineage", evidence)

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "regression exceeds 15% without an accepted issue"
  end

  test "rejects copied-lineage evidence that targets Skillit or skips SDK-first sequencing" do
    evidence = m6_evidence
    evidence["provenance"]["target_is_skillit"] = true
    evidence["provenance"]["skillit_repository_changed"] = true
    evidence["route"]["sdk_upgraded_behind_legacy_endpoint"] = false
    accept("copied_lineage", evidence)

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "M6 may not target Skillit"
    assert_includes stderr, "M6 may not change the Skillit repository"
    assert_includes stderr, "upgrade the SDK behind the legacy endpoint"
  end

  test "rejects a copied-lineage host whose identity contradicts the non-Skillit declaration" do
    evidence = m6_evidence
    evidence["provenance"]["host"] = "Skillit"
    evidence["host"]["name"] = "Skillit"
    accept("copied_lineage", evidence)

    _stdout, stderr, status = run_verifier("--through", "M6")

    assert_not status.success?
    assert_includes stderr, "M6 host identity contradicts the non-Skillit declaration"
  end

  test "derives copied-lineage public API stability from both source commits" do
    evidence = m6_evidence
    evidence["friction"]["public_api"]["checkpoint_sha256"] = "9" * 64
    accept("copied_lineage", evidence)

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "public API checkpoint SHA differs from the RC1 source"
  end

  test "rejects a final source that does not descend from the adopted release train" do
    accept_final_inputs
    evidence = final_check_evidence
    evidence["release"]["source_commit"] = checkpoint("0.2.0.rc1").fetch("source_commit")
    evidence["release"]["source_tree"] = checkpoint("0.2.0.rc1").fetch("source_tree")
    accept("final_check", evidence)

    _stdout, stderr, status = run_verifier

    assert_not status.success?
    assert_includes stderr, "final source must strictly descend from M7"
  end

  test "recomputes copied-lineage benchmark medians from five zero-error runs" do
    evidence = m6_evidence
    list_result = evidence["benchmark"]["operations"].find { |operation| operation["name"] == "tools/list" }
    list_result["old_runs"].first["errors"] = 1
    list_result["new_runs"].pop
    list_result["old_median_p95_ms"] = 99.0
    accept("copied_lineage", evidence)

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "old run 1 must have zero errors"
    assert_includes stderr, "new must contain exactly five runs"
    assert_includes stderr, "old median p95 drifted from its five runs"
  end

  test "requires source-bound internal RC checkpoint bytes after publication deferral" do
    evidence = m6_evidence
    evidence["checkpoint"]["source_commit"] = "f" * 40
    accept("copied_lineage", evidence)
    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "artifact proof failed"
    assert_includes stderr, "cat-file"

    reset_fixture
    evidence = m6_evidence
    evidence["checkpoint"]["source_tree"] = "e" * 40
    accept("copied_lineage", evidence)
    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "source tree differs"

    reset_fixture
    evidence = m6_evidence
    evidence["checkpoint"]["sha256"] = "d" * 64
    accept("copied_lineage", evidence)
    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "rebuilt gem SHA-256 differs"

    reset_fixture
    evidence = m6_evidence
    evidence["checkpoint"]["status"] = "accepted_public_checkpoint"
    accept("copied_lineage", evidence)
    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "must remain internal after the M5.4 publication deferral"
  end

  test "rejects independent adoption that weakens host policy" do
    accept("copied_lineage", m6_evidence)
    evidence = m7_evidence
    evidence["policy_mapping"]["host_policy_weakened"] = true
    accept("independent", evidence)

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "must not weaken host policy"
  end

  test "requires independent adoption to use a distinct host and private report" do
    copied = m6_evidence
    accept("copied_lineage", copied)
    evidence = m7_evidence
    evidence["provenance"]["host"] = copied.dig("host", "name")
    evidence["host"]["name"] = copied.dig("host", "name")
    evidence["host"]["identity_sha256"] = copied.dig("host", "identity_sha256")
    evidence["approval"]["host_identity_sha256"] = copied.dig("host", "identity_sha256")
    evidence["host"]["private_report_sha256"] = copied.dig("host", "private_report_sha256")
    %w[host_ci mcp_smoke isolation].each do |gate|
      evidence.dig("gates", gate)["report_sha256"] = copied.dig("host", "private_report_sha256")
    end
    accept("independent", evidence)

    _stdout, stderr, status = run_verifier("--through", "M7")

    assert_not status.success?
    assert_includes stderr, "M7 host must differ from the copied-lineage host"
    assert_includes stderr, "M7 private report must differ from the copied-lineage report"
  end

  test "requires fixed source-bound milestone local gate reports" do
    evidence = m6_evidence
    evidence.dig("gates", "package_smoke")["command"] = "true"
    evidence.dig("gates", "package_smoke")["report_sha256"] = "0" * 64
    accept("copied_lineage", evidence)

    _stdout, stderr, status = run_verifier("--through", "M6")

    assert_not status.success?
    assert_includes stderr, "M6 gate package_smoke command drifted"

    reset_fixture
    evidence = m6_evidence
    local_gate = evidence.dig("gates", "package_smoke")
    local_gate.dig("report", "candidate")["sha256"] = "9" * 64
    local_gate["report_sha256"] = Digest::SHA256.hexdigest(
      "#{JSON.pretty_generate(local_gate.fetch('report'))}\n"
    )
    accept("copied_lineage", evidence)

    _stdout, stderr, status = run_verifier("--through", "M6")

    assert_not status.success?
    assert_includes stderr, "did not run against the accepted checkpoint"

    reset_fixture
    accept("copied_lineage", m6_evidence)
    evidence = m7_evidence
    evidence.dig("gates", "mutation_mcp")["command"] = "true"
    evidence.dig("gates", "mutation_mcp")["report_sha256"] = "1" * 64
    accept("independent", evidence)

    _stdout, stderr, status = run_verifier("--through", "M7")

    assert_not status.success?
    assert_includes stderr, "M7 gate mutation_mcp command drifted"
  end

  test "requires M7 framework-change declarations to match their friction items" do
    accept("copied_lineage", m6_evidence)
    evidence = m7_evidence
    evidence["friction"]["items"] << {
      "description" => "Independent adoption required a framework correction",
      "disposition" => "framework_change",
      "framework_test" => "test/tooling/release_evidence_test.rb"
    }
    accept("independent", evidence)

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "framework_changed must match its friction items"
    assert_includes stderr, "framework change proofs must match every framework friction test"
  end

  test "derives M6 framework changes from checkpoint source and requires an output rerun" do
    evidence = m6_evidence
    File.write(File.join(@root, "lib/hitch/undeclared_m6_change.rb"), "module Hitch::UndeclaredM6Change; end\n")
    git!("add", "lib/hitch/undeclared_m6_change.rb")
    git!("commit", "--quiet", "-m", "Undeclared M6 framework change")
    rebind_checkpoint_to_head("0.2.0.rc1")
    evidence["checkpoint"] = checkpoint("0.2.0.rc1")
    evidence["friction"]["public_api"] = m6_public_api_proof
    accept("copied_lineage", evidence)

    _stdout, stderr, status = run_verifier

    assert_not status.success?
    assert_includes stderr, "M6 framework_changed must match the checkpoint source delta"
    assert_includes stderr, "M6 output rerun must pass"
  end

  test "does not hide M6 runtime code inside the mechanical version file" do
    evidence = m6_evidence
    version_path = File.join(@root, "lib/hitch/version.rb")
    File.write(version_path, File.read(version_path).sub("end\n", "  RUNTIME_SMUGGLE = true\nend\n"))
    git!("add", "lib/hitch/version.rb")
    git!("commit", "--quiet", "-m", "Smuggle runtime code into the RC1 version file")
    rebind_checkpoint_to_head("0.2.0.rc1")
    evidence["checkpoint"] = checkpoint("0.2.0.rc1")
    evidence["friction"]["public_api"] = m6_public_api_proof
    accept("copied_lineage", evidence)

    _stdout, stderr, status = run_verifier("--through", "M6")

    assert_not status.success?
    assert_includes stderr,
      "M6 source delta version file may change only the exact VERSION literal from 0.2.0.pre.4 to 0.2.0.rc1"
    assert_includes stderr, "M6 framework_changed must match the checkpoint source delta"
  end

  test "treats M6 gemspec dependency drift as a framework change" do
    evidence = m6_evidence
    gemspec_path = File.join(@root, "hitch-rails.gemspec")
    File.write(
      gemspec_path,
      File.read(gemspec_path).sub("end\n", "  spec.add_dependency \"runtime-added-during-adoption\"\nend\n")
    )
    git!("add", "hitch-rails.gemspec")
    git!("commit", "--quiet", "-m", "Add an M6 runtime dependency")
    rebind_checkpoint_to_head("0.2.0.rc1")
    evidence["checkpoint"] = checkpoint("0.2.0.rc1")
    evidence["friction"]["public_api"] = m6_public_api_proof
    accept("copied_lineage", evidence)

    _stdout, stderr, status = run_verifier("--through", "M6")

    assert_not status.success?
    assert_includes stderr, "M6 framework_changed must match the checkpoint source delta"
    assert_includes stderr, "M6 output rerun must pass"
  end

  test "requires RC1 to descend strictly from the accepted pre4 source" do
    evidence = m6_evidence
    rc1 = checkpoint("0.2.0.rc1")
    unrelated_commit = git!(
      "commit-tree",
      rc1.fetch("source_tree"),
      "-m",
      "Unrelated RC1 root with the same tree"
    ).strip
    rebind_checkpoint("0.2.0.rc1", commit: unrelated_commit)
    evidence["checkpoint"] = checkpoint("0.2.0.rc1")
    evidence["friction"]["public_api"] = m6_public_api_proof
    accept("copied_lineage", evidence)

    _stdout, stderr, status = run_verifier("--through", "M6")

    assert_not status.success?
    assert_includes stderr, "M6 source must strictly descend from the accepted pre4 source"
  end

  test "rejects an undeclared framework source delta between M6 and RC2" do
    accept("copied_lineage", m6_evidence)
    File.write(File.join(@root, "lib/hitch/undeclared_m7_change.rb"), "module Hitch::UndeclaredM7Change; end\n")
    git!("add", "lib/hitch/undeclared_m7_change.rb")
    git!("commit", "--quiet", "-m", "Undeclared M7 framework change")
    accept("independent", m7_evidence)

    _stdout, stderr, status = run_verifier

    assert_not status.success?
    assert_includes stderr, "M7 framework_changed must match the checkpoint source delta"
    assert_includes stderr, "M7 copied-host rerun must pass"
    assert_includes stderr, "M7 independent-host rerun must pass"
  end

  test "treats M7 gemspec dependency drift as a framework change" do
    accept("copied_lineage", m6_evidence)
    evidence = m7_evidence
    gemspec_path = File.join(@root, "hitch-rails.gemspec")
    File.write(
      gemspec_path,
      File.read(gemspec_path).sub("end\n", "  spec.add_dependency \"runtime-added-during-independent-adoption\"\nend\n")
    )
    git!("add", "hitch-rails.gemspec")
    git!("commit", "--quiet", "-m", "Add an M7 runtime dependency")
    rebind_checkpoint_to_head("0.2.0.rc2")
    evidence["checkpoint"] = checkpoint("0.2.0.rc2")
    accept("independent", evidence)

    _stdout, stderr, status = run_verifier("--through", "M7")

    assert_not status.success?
    assert_includes stderr, "M7 framework_changed must match the checkpoint source delta"
    assert_includes stderr, "M7 copied-host rerun must pass"
    assert_includes stderr, "M7 independent-host rerun must pass"
  end

  test "does not hide M7 runtime code inside the mechanical version file" do
    accept("copied_lineage", m6_evidence)
    evidence = m7_evidence
    version_path = File.join(@root, "lib/hitch/version.rb")
    File.write(version_path, File.read(version_path).sub("end\n", "  RUNTIME_SMUGGLE = true\nend\n"))
    git!("add", "lib/hitch/version.rb")
    git!("commit", "--quiet", "-m", "Smuggle runtime code into the RC2 version file")
    rebind_checkpoint_to_head("0.2.0.rc2")
    evidence["checkpoint"] = checkpoint("0.2.0.rc2")
    accept("independent", evidence)

    _stdout, stderr, status = run_verifier("--through", "M7")

    assert_not status.success?
    assert_includes stderr,
      "M7 source delta version file may change only the exact VERSION literal from 0.2.0.rc1 to 0.2.0.rc2"
    assert_includes stderr, "M7 framework_changed must match the checkpoint source delta"
  end

  test "accepts a source-derived M7 change only with failing-test proof and exact host reruns" do
    accept("copied_lineage", m6_evidence)
    test_path = "test/hitch/independent_adoption_regression_test.rb"
    absolute_test_path = File.join(@root, test_path)
    FileUtils.mkdir_p(File.dirname(absolute_test_path))
    File.write(absolute_test_path, "# unchanged failing regression test\n")
    git!("add", test_path)
    git!("commit", "--quiet", "-m", "Add failing independent-adoption regression")
    before_commit = git!("rev-parse", "HEAD").strip
    before_tree = git!("rev-parse", "HEAD^{tree}").strip
    test_sha = Digest::SHA256.file(absolute_test_path).hexdigest

    implementation_path = "lib/hitch/independent_adoption_fix.rb"
    File.write(File.join(@root, implementation_path), "module Hitch::IndependentAdoptionFix; end\n")
    git!("add", implementation_path)
    git!("commit", "--quiet", "-m", "Fix independent-adoption regression")

    evidence = m7_evidence
    rc2 = evidence.fetch("checkpoint")
    checkpoint_time = Time.iso8601(
      git!("show", "--no-patch", "--format=%cI", rc2.fetch("source_commit")).strip
    )
    evidence["verified_at"] = (checkpoint_time + 30).iso8601
    evidence["friction"] = {
      "items" => [
        {
          "description" => "Independent adoption exposed a reusable framework defect",
          "disposition" => "framework_change",
          "framework_test" => test_path
        }
      ],
      "framework_changed" => true,
      "framework_change_proofs" => [
        {
          "test" => test_path,
          "command" => "bin/ci-test #{test_path}",
          "before_source_commit" => before_commit,
          "before_source_tree" => before_tree,
          "before_status" => "failed",
          "before_output_sha256" => "7" * 64,
          "before_test_sha256" => test_sha,
          "after_source_commit" => rc2.fetch("source_commit"),
          "after_source_tree" => rc2.fetch("source_tree"),
          "after_status" => "passed",
          "after_output_sha256" => "8" * 64,
          "after_test_sha256" => test_sha
        }
      ],
      "m6_rerun" => passed_rerun(
        host: "Approved Copied Host",
        checkpoint: rc2,
        verified_at: (checkpoint_time + 10).iso8601,
        report_sha256: "c" * 64
      ),
      "m7_rerun" => passed_rerun(
        host: "Independent Host",
        checkpoint: rc2,
        verified_at: (checkpoint_time + 20).iso8601,
        report_sha256: "d" * 64
      )
    }
    accept("independent", evidence)

    _stdout, stderr, status = run_verifier

    assert_predicate status, :success?, stderr
  end

  test "rejects a framework implementation committed before its claimed failing test" do
    accept("copied_lineage", m6_evidence)
    implementation_path = "lib/hitch/implementation_before_test.rb"
    File.write(File.join(@root, implementation_path), "module Hitch::ImplementationBeforeTest; end\n")
    git!("add", implementation_path)
    git!("commit", "--quiet", "-m", "Implement the adoption fix before its regression test")

    test_path = "test/hitch/late_adoption_regression_test.rb"
    absolute_test_path = File.join(@root, test_path)
    FileUtils.mkdir_p(File.dirname(absolute_test_path))
    File.write(absolute_test_path, "# claimed failing regression test added too late\n")
    git!("add", test_path)
    git!("commit", "--quiet", "-m", "Add the claimed failing regression after the implementation")
    before_commit = git!("rev-parse", "HEAD").strip
    before_tree = git!("rev-parse", "HEAD^{tree}").strip
    test_sha = Digest::SHA256.file(absolute_test_path).hexdigest

    unrelated_path = "lib/hitch/unrelated_post_test_change.rb"
    File.write(File.join(@root, unrelated_path), "module Hitch::UnrelatedPostTestChange; end\n")
    git!("add", unrelated_path)
    git!("commit", "--quiet", "-m", "Add an unrelated post-test framework change")

    evidence = m7_evidence
    rc2 = evidence.fetch("checkpoint")
    checkpoint_time = Time.iso8601(
      git!("show", "--no-patch", "--format=%cI", rc2.fetch("source_commit")).strip
    )
    evidence["verified_at"] = (checkpoint_time + 30).iso8601
    evidence["friction"] = {
      "items" => [
        {
          "description" => "Claimed test-first independent-adoption correction",
          "disposition" => "framework_change",
          "framework_test" => test_path
        }
      ],
      "framework_changed" => true,
      "framework_change_proofs" => [
        {
          "test" => test_path,
          "command" => "bin/ci-test #{test_path}",
          "before_source_commit" => before_commit,
          "before_source_tree" => before_tree,
          "before_status" => "failed",
          "before_output_sha256" => "7" * 64,
          "before_test_sha256" => test_sha,
          "after_source_commit" => rc2.fetch("source_commit"),
          "after_source_tree" => rc2.fetch("source_tree"),
          "after_status" => "passed",
          "after_output_sha256" => "8" * 64,
          "after_test_sha256" => test_sha
        }
      ],
      "m6_rerun" => passed_rerun(
        host: "Approved Copied Host",
        checkpoint: rc2,
        verified_at: (checkpoint_time + 10).iso8601,
        report_sha256: "c" * 64
      ),
      "m7_rerun" => passed_rerun(
        host: "Independent Host",
        checkpoint: rc2,
        verified_at: (checkpoint_time + 20).iso8601,
        report_sha256: "d" * 64
      )
    }
    accept("independent", evidence)

    _stdout, stderr, status = run_verifier("--through", "M7")

    assert_not status.success?
    assert_includes stderr, "M7 framework change proof 1 framework implementation changed before the failing test"
  end

  test "requires final evidence to retain visible probes skips and exclusions" do
    accept_preflight
    evidence = final_check_evidence
    evidence["conformance"]["untestable_capability_probes"] = []
    accept("final_check", evidence)

    _stdout, stderr, status = run_verifier("--preflight", "0.2.0")
    assert_not status.success?
    assert_includes stderr, "retain the two documented untestable probes"
  end

  test "requires separate publication authority for the exact accepted final candidate" do
    accept_final_inputs
    accept("final_check", final_check_evidence)

    _stdout, stderr, status = run_verifier("--preflight", "0.2.0")
    assert_not status.success?
    assert_includes stderr, "release/final-publication-authority.json"

    evidence = publication_authority_evidence
    evidence["candidate"]["sha256"] = "8" * 64
    accept("publication_authority", evidence)
    _stdout, stderr, status = run_verifier("--preflight", "0.2.0")
    assert_not status.success?
    assert_includes stderr, "candidate differs from the accepted final check"
  end

  test "requires Tyler Klose to grant final publication authority" do
    accept_preflight
    evidence = publication_authority_evidence
    evidence["authority"]["authorized_by"] = "Unassigned Maintainer"
    accept("publication_authority", evidence)

    _stdout, stderr, status = run_verifier("--preflight", "0.2.0")

    assert_not status.success?
    assert_includes stderr, "publication authority must be Tyler Klose"
  end

  test "requires exact roadmap product-client versions and complete disposable MCP smokes" do
    accept("copied_lineage", m6_evidence)
    accept("independent", m7_evidence)
    evidence = product_client_evidence
    evidence["clients"].first["version"] = "1.0"
    evidence["clients"].last["command"] = ""
    evidence["clients"].last["report_sha256"] = "not-a-sha"
    evidence["clients"].first["checks"]["tools_call"] = "not_run"
    evidence["clients"].last["target"]["artifact_sha256"] = "9" * 64
    evidence["clients"].last["side_effects"]["production_mutations"] = true
    evidence["clients"].first["started_at"] = "2026-08-03T02:29:59Z"
    evidence["clients"].last["completed_at"] = "2026-08-03T02:45:59Z"
    evidence["clients"].last["target"]["resource_uri"] = "http://localhost:3102/mcp?unexpected=true"
    accept("product_clients", evidence)

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "exact roadmap-pinned versions"
    assert_includes stderr, "needs a redacted command"
    assert_includes stderr, "report needs a SHA-256 pin"
    assert_includes stderr, "did not prove the complete MCP smoke"
    assert_includes stderr, "target artifact differs from the approved input"
    assert_includes stderr, "may not mutate production"
    assert_includes stderr, "started before explicit approval is out of order"
    assert_includes stderr, "completed before it started is out of order"
    assert_includes stderr, "resource URI must be loopback /mcp"
  end

  test "requires a distinct report for each pinned product client" do
    accept("copied_lineage", m6_evidence)
    accept("independent", m7_evidence)
    evidence = product_client_evidence
    evidence["clients"].last["report_sha256"] = evidence["clients"].first["report_sha256"]
    accept("product_clients", evidence)

    _stdout, stderr, status = run_verifier

    assert_not status.success?
    assert_includes stderr, "product-client reports must be distinct"
  end

  test "binds hosted matrix evidence to the candidate workflow and exact lanes" do
    accept("copied_lineage", m6_evidence)
    accept("independent", m7_evidence)
    accept("product_clients", product_client_evidence)
    evidence = hosted_matrix_evidence
    evidence["workflow"]["sha256"] = "9" * 64
    evidence["lanes"].last["ruby"] = "3.3"
    evidence["provider"]["head_sha"] = checkpoint("0.2.0.rc2").fetch("source_commit")
    evidence["provider"]["repository"] = "another-owner/hitch-rails"
    evidence["provider"]["event"] = "pull_request"
    evidence["provider"]["run_attempt"] = 2
    evidence["lanes"].last["job_id"] = evidence["lanes"].first["job_id"]
    evidence["lanes"].first["started_at"] = "2026-08-03T03:04:59Z"
    accept("hosted_matrix", evidence)

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "workflow SHA differs from the candidate source"
    assert_includes stderr, "lanes must match every contracted lane"
    assert_includes stderr, "run did not execute the candidate commit"
    assert_includes stderr, "repository drifted"
    assert_includes stderr, "event must be push"
    assert_includes stderr, "attempt differs from its run"
    assert_includes stderr, "distinct jobs"
    assert_includes stderr, "started before its run is out of order"
  end

  test "requires generated final local gates with exact commands and derived output pins" do
    accept("copied_lineage", m6_evidence)
    accept("independent", m7_evidence)
    accept("product_clients", product_client_evidence)
    evidence = final_local_gates_evidence
    evidence["gates"]["conformance"]["argv"] = [ [ "bin/contract" ] ]
    evidence["gates"]["full_ci"]["command_output_sha256s"] = []
    evidence["gates"]["documentation"]["output_sha256"] = "not-a-sha"
    accept("final_local_gates", evidence)

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "final local gate conformance argv drifted"
    assert_includes stderr, "final local gate full_ci must retain one output hash per command"
    assert_includes stderr, "final local gate documentation output needs a SHA-256 pin"
    assert_includes stderr, "final local gate documentation aggregate output hash drifted"
  end

  test "requires every hosted and local final gate to start after product evidence acceptance" do
    accept("copied_lineage", m6_evidence)
    accept("independent", m7_evidence)
    accept("product_clients", product_client_evidence)
    hosted = hosted_matrix_evidence
    hosted["provider"]["started_at"] = "2026-08-03T02:59:59Z"
    accept("hosted_matrix", hosted)
    local = final_local_gates_evidence
    local["gates"]["full_ci"]["started_at"] = "2026-08-03T02:59:59Z"
    accept("final_local_gates", local)

    _stdout, stderr, status = run_verifier

    assert_not status.success?
    assert_includes stderr, "hosted matrix run started before product-client acceptance is out of order"
    assert_includes stderr, "final local gate full_ci started before product-client acceptance is out of order"
  end

  test "final check binds every local gate and the hosted matrix indexed reports" do
    accept_final_inputs
    evidence = final_check_evidence
    evidence["gates"]["full_ci"]["report_sha256"] = "9" * 64
    evidence["gates"]["all_matrix_lanes"]["report_sha256"] = "8" * 64
    accept("final_check", evidence)

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "gate full_ci must bind accepted final_local_gates evidence"
    assert_includes stderr, "gate all_matrix_lanes must bind accepted hosted_matrix evidence"
  end

  test "enforces the approval and verification chronology" do
    accept_preflight
    evidence = publication_authority_evidence
    evidence["authority"]["approved_at"] = "2026-08-03T03:59:59Z"
    accept("publication_authority", evidence)

    _stdout, stderr, status = run_verifier("--preflight", "0.2.0")
    assert_not status.success?
    assert_includes stderr, "publication authority before final verification is out of order"

    reset_fixture
    accept("copied_lineage", m6_evidence)
    evidence = m7_evidence
    evidence["approval"]["approved_at"] = "2026-08-03T02:00:01Z"
    accept("independent", evidence)
    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "independent verification before its approval is out of order"

    reset_fixture
    accept_final_inputs
    evidence = final_check_evidence
    evidence["approvals"]["maintainer_review"]["approved_at"] = "2026-08-03T03:30:00Z"
    accept("final_check", evidence)
    _stdout, stderr, status = run_verifier("--ready-for-authority", "0.2.0")
    assert_not status.success?
    assert_includes stderr, "final maintainer approval before final_local_gates verification is out of order"

    reset_fixture
    prior_record = record_for("automated_client_smokes")
    prior_evidence = JSON.parse(File.read(File.join(@root, prior_record.fetch("path"))))
    prior_evidence["verified_at"] = "2026-08-03T04:30:00Z"
    accept("automated_client_smokes", prior_evidence)
    accept_final_inputs
    accept("final_check", final_check_evidence)
    _stdout, stderr, status = run_verifier("--ready-for-authority", "0.2.0")
    assert_not status.success?
    assert_includes stderr,
      "final maintainer approval before automated_client_smokes verification is out of order"

    reset_fixture
    decision = JSON.parse(File.read(File.join(@root, DECISION_PATH)))
    decision["recorded_at"] = "2026-08-03T04:30:00Z"
    accept("pre4_publication_decision", decision)
    accept_final_inputs
    accept("final_check", final_check_evidence)
    _stdout, stderr, status = run_verifier("--ready-for-authority", "0.2.0")
    assert_not status.success?
    assert_includes stderr,
      "final maintainer approval before pre4_publication_decision recorded_at is out of order"

    reset_fixture
    verification_record = record_for("contract_verification")
    verification = JSON.parse(File.read(File.join(@root, verification_record.fetch("path"))))
    verification["verified_on"] = "2026-08-04"
    accept("contract_verification", verification)
    accept_final_inputs
    accept("final_check", final_check_evidence)
    _stdout, stderr, status = run_verifier("--ready-for-authority", "0.2.0")
    assert_not status.success?
    assert_includes stderr,
      "final maintainer approval before contract_verification verified_on is out of order"

    reset_fixture
    prior_record = record_for("automated_client_smokes")
    prior_evidence = JSON.parse(File.read(File.join(@root, prior_record.fetch("path"))))
    prior_evidence["verified_at"] = "not-a-time"
    prior_evidence["recorded_at"] = "2026-08-02T23:29:49Z"
    accept("automated_client_smokes", prior_evidence)
    accept_final_inputs
    accept("final_check", final_check_evidence)
    _stdout, stderr, status = run_verifier("--ready-for-authority", "0.2.0")
    assert_not status.success?
    assert_includes stderr,
      "final prerequisite automated_client_smokes requires parseable " \
      "automated_client_smokes.verified_at completion value"

    reset_fixture
    prior_record = record_for("automated_client_smokes")
    prior_evidence = JSON.parse(File.read(File.join(@root, prior_record.fetch("path"))))
    prior_evidence.delete("verified_at")
    prior_evidence["recorded_at"] = "2026-08-02T23:29:49Z"
    accept("automated_client_smokes", prior_evidence)
    accept_final_inputs
    accept("final_check", final_check_evidence)
    _stdout, stderr, status = run_verifier("--ready-for-authority", "0.2.0")
    assert_not status.success?
    assert_includes stderr,
      "final prerequisite automated_client_smokes requires parseable " \
      "automated_client_smokes.verified_at completion value"

    reset_fixture
    verification_record = record_for("work_packet_verification")
    verification = JSON.parse(File.read(File.join(@root, verification_record.fetch("path"))))
    verification.delete("verified_on")
    accept("work_packet_verification", verification)
    accept_final_inputs
    accept("final_check", final_check_evidence)
    _stdout, stderr, status = run_verifier("--ready-for-authority", "0.2.0")
    assert_not status.success?
    assert_includes stderr,
      "final prerequisite work_packet_graph requires parseable " \
      "work_packet_verification.verified_on completion value"
    assert_includes stderr,
      "final prerequisite work_packet_verification requires parseable " \
      "work_packet_verification.verified_on completion value"

    reset_fixture
    graph_record = record_for("work_packet_graph")
    graph = JSON.parse(File.read(File.join(@root, graph_record.fetch("path"))))
    graph["source"] = "ROADMAP.md#changed-after-verification"
    accept("work_packet_graph", graph)
    accept_final_inputs
    accept("final_check", final_check_evidence)
    _stdout, stderr, status = run_verifier("--ready-for-authority", "0.2.0")
    assert_not status.success?
    assert_includes stderr,
      "work_packet_graph completion authority must bind its accepted path and SHA-256"
  end

  test "requires a named release-maintainer final review" do
    accept_final_inputs
    evidence = final_check_evidence
    evidence["approvals"]["maintainer_review"]["reviewed_by"] = ""
    evidence["approvals"]["maintainer_review"]["role"] = "contributor"
    accept("final_check", evidence)

    _stdout, stderr, status = run_verifier("--ready-for-authority", "0.2.0")

    assert_not status.success?
    assert_includes stderr, "maintainer review needs a named reviewer"
    assert_includes stderr, "role must be release_maintainer"
  end

  test "rejects every out-of-order evidence acceptance transition" do
    scenarios = [
      [ "independent", "M7 evidence cannot be accepted before M6" ],
      [ "product_clients", "M8 preflight evidence cannot be accepted before M7" ],
      [ "hosted_matrix", "hosted_matrix evidence cannot be accepted before product clients" ],
      [ "final_local_gates", "final_local_gates evidence cannot be accepted before product clients" ],
      [ "final_check", "final-check evidence cannot be accepted before hosted matrix evidence" ],
      [ "publication_authority", "publication authority cannot be accepted before final-check evidence" ],
      [ "downloaded_gem", "downloaded gem evidence cannot be accepted before publication authority" ]
    ]

    scenarios.each do |kind, message|
      reset_fixture
      accept(kind, {})

      _stdout, stderr, status = run_verifier

      assert_not status.success?, kind
      assert_includes stderr, message, kind
    end
  end

  test "rejects hidden final requirements and undocumented public API" do
    accept_preflight
    evidence = final_check_evidence
    evidence["requirements"]["hidden_client_requirements"] = [ "undocumented client prerequisite" ]
    evidence["public_api"]["undocumented_surfaces"] = [ "Hitch::Unexpected" ]
    accept("final_check", evidence)

    _stdout, stderr, status = run_verifier("--preflight", "0.2.0")
    assert_not status.success?
    assert_includes stderr, "hidden_client_requirements must be empty"
    assert_includes stderr, "may not retain undocumented public API"
  end

  test "rejects public API drift between RC2 and the final candidate" do
    accept("copied_lineage", m6_evidence)
    accept("independent", m7_evidence)
    path = File.join(@root, "docs/contracts/mcp_public_api.yml")
    manifest = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    manifest.fetch("entries") << {
      "name" => "Hitch::LatePublicSurface",
      "reload_behavior" => "Late and unadopted."
    }
    File.write(path, YAML.dump(manifest))
    git!("add", "docs/contracts/mcp_public_api.yml")
    git!("commit", "--quiet", "-m", "Late public API drift")
    accept_remaining_final_inputs
    accept("final_check", final_check_evidence)

    _stdout, stderr, status = run_verifier("--ready-for-authority", "0.2.0")

    assert_not status.success?
    assert_includes stderr, "final public API changed after M7"
  end

  test "rejects runtime drift between RC2 and the final candidate" do
    accept("copied_lineage", m6_evidence)
    accept("independent", m7_evidence)
    File.write(File.join(@root, "lib/hitch/late_runtime_change.rb"), "module Hitch::LateRuntimeChange; end\n")
    git!("add", "lib/hitch/late_runtime_change.rb")
    git!("commit", "--quiet", "-m", "Late runtime drift")
    accept_remaining_final_inputs
    accept("final_check", final_check_evidence)

    _stdout, stderr, status = run_verifier("--ready-for-authority", "0.2.0")

    assert_not status.success?
    assert_includes stderr, "final runtime changed after M7"
  end

  test "does not hide final runtime code inside the mechanical version file" do
    accept("copied_lineage", m6_evidence)
    accept("independent", m7_evidence)
    checkpoint("0.2.0")
    version_path = File.join(@root, "lib/hitch/version.rb")
    File.write(version_path, File.read(version_path).sub("end\n", "  FINAL_RUNTIME_SMUGGLE = true\nend\n"))
    git!("add", "lib/hitch/version.rb")
    git!("commit", "--quiet", "-m", "Smuggle runtime code into the final version file")
    rebind_checkpoint_to_head("0.2.0")
    accept_remaining_final_inputs
    accept("final_check", final_check_evidence)

    _stdout, stderr, status = run_verifier("--ready-for-authority", "0.2.0")

    assert_not status.success?
    assert_includes stderr,
      "M8 post-adoption runtime delta version file may change only the exact VERSION literal from 0.2.0.rc2 to 0.2.0"
    assert_includes stderr, "final runtime changed after M7"
  end

  test "reconciles the committed downloaded gem with the accepted final bytes" do
    accept_preflight
    accept("downloaded_gem", downloaded_gem_evidence)

    stdout, stderr, status = run_verifier("--complete", "0.2.0")
    assert_predicate status, :success?, stderr
    assert_includes stdout, "live tag and RubyGems reconciliation"

    evidence = downloaded_gem_evidence
    evidence["rubygems"]["sha256"] = "9" * 64
    accept("downloaded_gem", evidence)
    _stdout, stderr, status = run_verifier("--complete", "0.2.0")
    assert_not status.success?
    assert_includes stderr, "bytes differ from the accepted final artifact"

    evidence = downloaded_gem_evidence
    evidence["repository"]["target_commit"] = "9" * 40
    accept("downloaded_gem", evidence)
    _stdout, stderr, status = run_verifier("--complete", "0.2.0")
    assert_not status.success?
    assert_includes stderr, "tag target differs from the accepted final source"
  end

  private

  def reset_fixture
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
    @root = Dir.mktmpdir("hitch-release-evidence")
    @index = nil
    @release_checkpoints = {}
    @real_release_artifacts = false
    FileUtils.mkdir_p(File.join(@root, "docs/contracts"))
    FileUtils.cp(REPOSITORY_ROOT.join(CONTRACT_PATH), File.join(@root, CONTRACT_PATH))
    FileUtils.cp(
      REPOSITORY_ROOT.join("docs/contracts/release_matrix.yml"),
      File.join(@root, "docs/contracts/release_matrix.yml")
    )
    FileUtils.mkdir_p(File.join(@root, "docs/evidence"))
    FileUtils.cp_r(REPOSITORY_ROOT.join("docs/evidence/0.2.0"), File.join(@root, "docs/evidence"))
  end

  def run_verifier(*arguments)
    options = parse_options([ "--root", @root, *arguments ])
    authenticator = lambda do |commit:, version:, expected_tree:, expected_sha256:, **|
      expected = @release_checkpoints.fetch(version)
      unless commit == expected.fetch("source_commit")
        raise HitchReleaseArtifact::VerificationError, "git cat-file failed"
      end
      unless expected_tree == expected.fetch("source_tree")
        raise HitchReleaseArtifact::VerificationError,
          "source tree differs: expected #{expected_tree}, got #{expected.fetch('source_tree')}"
      end
      unless expected_sha256 == expected.fetch("sha256")
        raise HitchReleaseArtifact::VerificationError,
          "rebuilt gem SHA-256 differs: expected #{expected_sha256}, got #{expected.fetch('sha256')}"
      end

      {}
    end
    verifier = ReleaseEvidenceVerifier.new(options, artifact_authenticator: authenticator)
    errors = verifier.verify
    status = VerificationStatus.new(errors.empty?)
    stdout = errors.empty? ? "#{verifier.summary}\n" : ""
    stderr = errors.empty? ? "" : "#{errors.join("\n")}\n"
    [ stdout, stderr, status ]
  end

  def run_cli_verifier(*arguments)
    Open3.capture3(RbConfig.ruby, VERIFIER, "--root", @root, *arguments)
  end

  def index
    @index ||= JSON.parse(File.read(File.join(@root, INDEX_PATH)))
  end

  def save_index
    write_json(INDEX_PATH, index)
  end

  def record_for(kind)
    index.fetch("records").find { |record| record["kind"] == kind } ||
      raise("missing index record #{kind}")
  end

  def accept(kind, evidence)
    record = record_for(kind)
    write_json(record.fetch("path"), evidence)
    record["status"] = "accepted"
    record["sha256"] = Digest::SHA256.file(File.join(@root, record.fetch("path"))).hexdigest
    save_index
  end

  def accept_preflight
    accept_final_inputs
    accept("final_check", final_check_evidence)
    accept("publication_authority", publication_authority_evidence)
  end

  def accept_final_inputs
    accept("copied_lineage", m6_evidence)
    accept("independent", m7_evidence)
    accept_remaining_final_inputs
  end

  def accept_remaining_final_inputs
    accept("rate_limit_cross_process", rate_limit_cross_process_evidence)
    accept("product_clients", product_client_evidence)
    accept("hosted_matrix", hosted_matrix_evidence)
    accept("final_local_gates", final_local_gates_evidence)
  end

  def rate_limit_cross_process_evidence
    {
      "schema" => "hitch.m4.3-rate-limit-cross-process-evidence.v1",
      "milestone" => "M4.3",
      "status" => "verified_internal_rate_boundary",
      "verified_at" => "2026-08-02T10:26:59Z"
    }
  end

  def m6_evidence
    host_name = "Approved Copied Host"
    input_artifact = "hitch-rails-0.2.0.pre.4.gem"
    input_sha256 = "e31a7636a4321026c4b10deaafddc1d396615622a5637b840285312c12870b31"
    {
      "schema" => "hitch.m6-copied-lineage-adoption.v1",
      "milestone" => "M6",
      "status" => "accepted",
      "verified_at" => "2026-08-03T01:00:00Z",
      "approval" => approval("M6", host_name, input_sha256),
      "provenance" => {
        "class" => "copied_lineage",
        "host" => host_name,
        "basis" => "approved_lineage_substitute",
        "substitution_approved" => true,
        "target_is_skillit" => false,
        "skillit_repository_changed" => false
      },
      "input" => {
        "version" => "0.2.0.pre.4",
        "kind" => JSON.parse(File.read(File.join(@root, DECISION_PATH))).dig("m6_input", "kind"),
        "artifact" => input_artifact,
        "sha256" => input_sha256
      },
      "host" => host(
        host_name,
        "a" * 40,
        "b" * 64,
        installed_artifact: input_artifact,
        installed_artifact_sha256: input_sha256
      ),
      "route" => route.merge("sdk_upgraded_behind_legacy_endpoint" => true),
      "parity" => {
        "tool_names" => "preserved",
        "schemas" => "preserved",
        "authentication" => "preserved",
        "audit_meaning" => "preserved",
        "business_policy_imported" => false,
        "migration_evidence_sha256" => nil
      },
      "benchmark" => {
        "same_host" => true,
        "same_data" => true,
        "warmed" => true,
        "concurrency" => 16,
        "runs" => 5,
        "operations" => %w[tools/list tools/call].map do |name|
          {
            "name" => name,
            "old_runs" => benchmark_runs([ 98.0, 99.0, 100.0, 101.0, 102.0 ]),
            "new_runs" => benchmark_runs([ 107.8, 108.9, 110.0, 111.1, 112.2 ]),
            "old_median_p95_ms" => 100.0,
            "new_median_p95_ms" => 110.0,
            "regression_percent" => 10.0,
            "accepted_performance_issue" => false,
            "accepted_issue" => nil
          }
        end
      },
      "friction" => {
        "items" => [],
        "public_api" => m6_public_api_proof,
        "framework_changed" => false,
        "framework_change_proofs" => [],
        "output_rerun" => not_applicable_rerun
      },
      "gates" => evidence_gates(
        %w[sdk_upgrade host_ci mcp_smoke isolation doctor package_smoke],
        external: %w[sdk_upgrade host_ci mcp_smoke isolation doctor],
        external_report_sha256: "b" * 64,
        milestone_local_reports: {
          "package_smoke" => milestone_local_report("M6", "package_smoke", checkpoint("0.2.0.rc1"))
        }
      ),
      "checkpoint" => checkpoint("0.2.0.rc1"),
      "redaction" => redaction
    }
  end

  def m7_evidence
    host_name = "Independent Host"
    input_checkpoint = checkpoint("0.2.0.rc1")
    {
      "schema" => "hitch.m7-independent-adoption.v1",
      "milestone" => "M7",
      "status" => "accepted",
      "verified_at" => "2026-08-03T02:00:00Z",
      "approval" => approval("M7", host_name, input_checkpoint.fetch("sha256")),
      "provenance" => {
        "class" => "independent",
        "host" => host_name,
        "basis" => "approved_independent_substitute",
        "substitution_approved" => true,
        "descended_from" => { "skillit" => false, "kaffe_karma" => false, "perfect_roofing" => false }
      },
      "input" => {
        "version" => "0.2.0.rc1",
        "kind" => "accepted_rc1_artifact",
        "artifact" => "hitch-rails-0.2.0.rc1.gem",
        "sha256" => input_checkpoint.fetch("sha256")
      },
      "host" => host(
        host_name,
        "e" * 40,
        "f" * 64,
        installed_artifact: input_checkpoint.fetch("artifact"),
        installed_artifact_sha256: input_checkpoint.fetch("sha256")
      ),
      "policy_mapping" => {
        "visibility_gate" => "available_to",
        "record_gate" => "authorize",
        "pundit_adapter_required" => false,
        "host_policy_weakened" => false,
        "business_policy_imported" => false
      },
      "route" => route,
      "isolation" => { "tool" => "passed", "principal" => "passed", "reload" => "passed" },
      "friction" => {
        "items" => [],
        "framework_changed" => false,
        "framework_change_proofs" => [],
        "m6_rerun" => not_applicable_rerun,
        "m7_rerun" => not_applicable_rerun
      },
      "gates" => evidence_gates(
        %w[host_ci mcp_smoke isolation mutation_mcp],
        external: %w[host_ci mcp_smoke isolation],
        external_report_sha256: "f" * 64,
        milestone_local_reports: {
          "mutation_mcp" => milestone_local_report("M7", "mutation_mcp", checkpoint("0.2.0.rc2"))
        }
      ),
      "checkpoint" => checkpoint("0.2.0.rc2"),
      "redaction" => redaction
    }
  end

  def product_client_evidence
    {
      "schema" => "hitch.m8-product-client-evidence.v1",
      "milestone" => "M8",
      "status" => "accepted",
      "verified_at" => "2026-08-03T03:00:00Z",
      "approval" => {
        "authority" => "Tyler Klose",
        "status" => "approved",
        "approved_at" => "2026-08-03T02:30:00Z"
      },
      "input" => final_artifact,
      "clients" => [
        {
          "name" => "Codex CLI",
          "version" => "0.146.0-alpha.3.1",
          "status" => "passed",
          "started_at" => "2026-08-03T02:40:00Z",
          "completed_at" => "2026-08-03T02:45:00Z",
          "command" => "codex mcp smoke --artifact hitch-rails-0.2.0.gem",
          "target" => {
            "kind" => "disposable_local_host",
            "resource_uri" => "http://127.0.0.1:3101/mcp",
            "artifact_sha256" => final_artifact.fetch("sha256")
          },
          "checks" => EXPECTED_PRODUCT_CHECKS.dup,
          "expected_tool" => "package.echo",
          "expected_result_sha256" => "1" * 64,
          "side_effects" => { "disposable_data_only" => true, "production_mutations" => false },
          "report_sha256" => "3" * 64
        },
        {
          "name" => "Claude Code",
          "version" => "2.1.220",
          "status" => "passed",
          "started_at" => "2026-08-03T02:46:00Z",
          "completed_at" => "2026-08-03T02:50:00Z",
          "command" => "claude mcp smoke --artifact hitch-rails-0.2.0.gem",
          "target" => {
            "kind" => "disposable_local_host",
            "resource_uri" => "http://localhost:3102/mcp",
            "artifact_sha256" => final_artifact.fetch("sha256")
          },
          "checks" => EXPECTED_PRODUCT_CHECKS.dup,
          "expected_tool" => "package.echo",
          "expected_result_sha256" => "2" * 64,
          "side_effects" => { "disposable_data_only" => true, "production_mutations" => false },
          "report_sha256" => "4" * 64
        }
      ],
      "redaction" => redaction
    }
  end

  def hosted_matrix_evidence
    final = checkpoint("0.2.0")
    workflow_bytes = git!("show", "#{final.fetch('source_commit')}:.github/workflows/ci.yml")
    matrix_contract = YAML.safe_load_file(
      File.join(@root, "docs/contracts/release_matrix.yml"),
      permitted_classes: [],
      aliases: false
    )
    {
      "schema" => "hitch.m8-hosted-matrix.v1",
      "milestone" => "M8",
      "status" => "accepted",
      "verified_at" => "2026-08-03T03:25:00Z",
      "approval" => {
        "reviewed_by" => "Release Maintainer",
        "role" => "release_maintainer",
        "status" => "approved",
        "reviewed_at" => "2026-08-03T03:20:00Z"
      },
      "candidate" => final.slice("version", "artifact", "sha256", "source_commit", "source_tree"),
      "provider" => {
        "name" => "GitHub Actions",
        "repository" => "tylerklose/hitch-rails",
        "head_repository" => "tylerklose/hitch-rails",
        "head_sha" => final.fetch("source_commit"),
        "event" => "push",
        "run_id" => 123_456_789,
        "run_attempt" => 1,
        "run_url" => "https://github.com/tylerklose/hitch-rails/actions/runs/123456789",
        "conclusion" => "success",
        "started_at" => "2026-08-03T03:05:00Z",
        "completed_at" => "2026-08-03T03:15:00Z",
        "raw_report_sha256" => "5" * 64
      },
      "workflow" => {
        "path" => ".github/workflows/ci.yml",
        "sha256" => Digest::SHA256.hexdigest(workflow_bytes)
      },
      "lanes" => matrix_contract.fetch("lanes").map.with_index(1) do |lane, offset|
        job_id = 9000 + offset
        {
          "name" => lane.fetch("name"),
          "ruby" => lane.fetch("ruby"),
          "job_id" => job_id,
          "job_name" => "Ruby #{lane.fetch('ruby')} / #{lane.fetch('rails')[/\d+\.\d+/]} / #{lane.fetch('adapter')}",
          "job_url" => "https://github.com/tylerklose/hitch-rails/actions/runs/123456789/job/#{job_id}",
          "run_attempt" => 1,
          "conclusion" => "success",
          "started_at" => "2026-08-03T03:06:00Z",
          "completed_at" => "2026-08-03T03:14:00Z"
        }
      end,
      "redaction" => redaction
    }
  end

  def final_local_gates_evidence
    final = checkpoint("0.2.0")
    {
      "schema" => "hitch.m8-final-local-gates.v1",
      "milestone" => "M8",
      "status" => "accepted",
      "verified_at" => "2026-08-03T03:50:00Z",
      "candidate" => final.slice("version", "artifact", "sha256", "source_commit", "source_tree").merge(
        "clean_worktree" => true
      ),
      "gates" => HitchFinalLocalGates::COMMANDS.each_with_index.to_h do |(name, argv), offset|
        started = Time.utc(2026, 8, 3, 3, 30, offset * 2)
        command_output_sha256s = argv.each_index.map do |command_offset|
          Digest::SHA256.hexdigest("#{name} command #{command_offset + 1} output")
        end
        structured_report_sha256s = if HitchFinalLocalGates::STRUCTURED_REPORT_GATES.key?(name)
          [ Digest::SHA256.hexdigest("#{name} candidate report") ]
        else
          []
        end
        [
          name,
          {
            "argv" => argv,
            "status" => "passed",
            "exit_statuses" => Array.new(argv.length, 0),
            "started_at" => started.iso8601,
            "completed_at" => (started + 1).iso8601,
            "command_output_sha256s" => command_output_sha256s,
            "structured_report_sha256s" => structured_report_sha256s,
            "output_sha256" => Digest::SHA256.hexdigest(JSON.generate(command_output_sha256s))
          }
        ]
      end,
      "redaction" => redaction.merge("raw_outputs_retained" => false)
    }
  end

  def final_check_evidence
    {
      "schema" => "hitch.m8-final-check.v1",
      "milestone" => "M8",
      "status" => "accepted",
      "verified_at" => "2026-08-03T04:00:00Z",
      "approvals" => {
        "copied_lineage" => "accepted",
        "independent" => "accepted",
        "product_clients" => "approved",
        "maintainer_review" => {
          "reviewed_by" => "Release Maintainer",
          "role" => "release_maintainer",
          "status" => "approved",
          "approved_at" => "2026-08-03T03:55:00Z"
        }
      },
      "release" => final_artifact.merge(
        "tag" => "v0.2.0",
        "source_commit" => checkpoint("0.2.0").fetch("source_commit"),
        "source_tree" => checkpoint("0.2.0").fetch("source_tree"),
        "clean_worktree" => true
      ),
      "prerequisites" => final_prerequisites,
      "gates" => evidence_gates(
        %w[
          full_ci all_matrix_lanes conformance package_apps automated_clients product_clients mutation_mcp
          copied_adoption independent_adoption documentation
        ],
        external: %w[all_matrix_lanes product_clients copied_adoption independent_adoption],
        linked_evidence: {
          "all_matrix_lanes" => "hosted_matrix",
          "product_clients" => "product_clients",
          "copied_adoption" => "copied_lineage",
          "independent_adoption" => "independent"
        },
        local_bundle_kind: "final_local_gates"
      ),
      "routes" => { "legacy_routes_absent" => true, "dual_route" => false },
      "security" => { "owned_controls" => true, "unowned_controls" => [] },
      "blockers" => [],
      "conformance" => {
        "unexpected_failures" => [],
        "unexplained_skips" => [],
        "stale_baseline_entries" => [],
        "untestable_capability_probes" => %w[
          server-stateless:sep-2575-server-rejects-undeclared-capability
          server-stateless:sep-2575-missing-capability-http-400
        ],
        "capability_gated_not_applicable" => %w[
          server-stateless:sep-2575-server-sends-subscription-ack
          server-stateless:sep-2575-server-tags-subscription-id
          server-stateless:sep-2575-server-honors-notification-filter
          server-stateless:sep-2575-server-sends-prompts-list-changed-on-subscription
          server-stateless:sep-2575-server-sends-tools-list-changed-on-subscription
        ],
        "exclusions" => {
          "caching" => "unconditionally probes prompts and resources, which Hitch 0.2 does not implement"
        }
      },
      "requirements" => {
        "hidden_database_requirements" => [],
        "hidden_client_requirements" => []
      },
      "public_api" => { "undocumented_surfaces" => [] },
      "evidence_index" => INDEX_PATH
    }
  end

  def downloaded_gem_evidence
    final = checkpoint("0.2.0")
    {
      "schema" => "hitch.m8-downloaded-gem.v1",
      "milestone" => "M8",
      "status" => "verified_published_artifact",
      "verified_at" => "2026-08-03T05:00:00Z",
      "publication_authority_sha256" => record_for("publication_authority").fetch("sha256"),
      "release" => "0.2.0",
      "rubygems" => {
        "artifact" => "hitch-rails-0.2.0.gem",
        "sha256" => final.fetch("sha256"),
        "files" => 50
      },
      "repository" => {
        "tag" => "v0.2.0",
        "tag_type" => "tag",
        "tagger" => "Release Maintainer",
        "tagged_at" => "2026-08-03T04:30:00Z",
        "annotation" => "Hitch 0.2.0",
        "target_commit" => final.fetch("source_commit"),
        "target_tree" => final.fetch("source_tree"),
        "remote_url" => "https://github.com/tylerklose/hitch-rails.git",
        "remote_tag_object" => "6" * 40,
        "remote_peeled_commit" => final.fetch("source_commit")
      },
      "checks" => {
        "version" => "match",
        "manifest" => "match",
        "forbidden_paths" => "absent",
        "file_checksums" => "match",
        "readme" => "match",
        "changelog" => "match",
        "security" => "match",
        "upgrading" => "match",
        "public_api" => "match"
      }
    }
  end

  def publication_authority_evidence
    final_record = record_for("final_check")
    final = JSON.parse(File.read(File.join(@root, final_record.fetch("path"))))
    {
      "schema" => "hitch.m8-publication-authority.v1",
      "milestone" => "M8",
      "status" => "accepted",
      "verified_at" => "2026-08-03T04:15:00Z",
      "authority" => {
        "authorized_by" => "Tyler Klose",
        "role" => "release_authority",
        "status" => "authorized",
        "approved_at" => "2026-08-03T04:10:00Z",
        "scope" => "create annotated v0.2.0 tag and publish hitch-rails 0.2.0 to RubyGems"
      },
      "candidate" => final.fetch("release").slice(
        "version", "artifact", "sha256", "source_commit", "source_tree", "tag"
      ),
      "final_check" => {
        "path" => final_record.fetch("path"),
        "sha256" => final_record.fetch("sha256")
      }
    }
  end

  def approval(milestone, host_name, input_artifact_sha256)
    {
      "authority" => "Tyler Klose",
      "status" => "approved",
      "approved_at" => "2026-08-03T00:30:00Z",
      "repository_access" => true,
      "deployment_access" => true,
      "host_identity_sha256" => host_identity_sha256(host_name),
      "input_artifact_sha256" => input_artifact_sha256,
      "scope" => MILESTONE_APPROVAL_SCOPES.fetch(milestone)
    }
  end

  def host(name, commit, report_sha, installed_artifact:, installed_artifact_sha256:)
    {
      "name" => name,
      "identity_sha256" => host_identity_sha256(name),
      "commit" => commit,
      "tree" => Digest::SHA1.hexdigest("#{name} source tree"),
      "clean_worktree" => true,
      "installed_artifact" => installed_artifact,
      "installed_artifact_sha256" => installed_artifact_sha256,
      "private_report_sha256" => report_sha
    }
  end

  def host_identity_sha256(name)
    Digest::SHA256.hexdigest("Tyler-approved private repository identity: #{name}")
  end

  def route
    {
      "preview" => "passed",
      "canonical_path" => "/mcp",
      "cutover" => "atomic",
      "legacy_dispatch_removed" => true,
      "dual_route" => false,
      "rollback" => "verified"
    }
  end

  def benchmark_runs(p95_values)
    p95_values.map do |p95_ms|
      { "requests" => 1_000, "errors" => 0, "p95_ms" => p95_ms }
    end
  end

  def checkpoint(version)
    release_checkpoint(version).slice(
      "version", "status", "source_commit", "source_tree", "artifact", "sha256"
    )
  end

  def rebind_checkpoint_to_head(version)
    commit = git!("rev-parse", "HEAD").strip
    rebind_checkpoint(version, commit:)
  end

  def rebind_checkpoint(version, commit:)
    release = @release_checkpoints.fetch(version)
    tree = git!("rev-parse", "#{commit}^{tree}").strip
    release["source_commit"] = commit
    release["source_tree"] = tree
    release["sha256"] = Digest::SHA256.hexdigest("fixture artifact #{version} #{commit} #{tree}")
  end

  def release_checkpoint(version)
    prepare_release_checkpoints_through(version)
    @release_checkpoints.fetch(version)
  end

  def prepare_release_checkpoints_through(version)
    versions = %w[0.2.0.rc1 0.2.0.rc2 0.2.0]
    versions.first(versions.index(version) + 1).each do |candidate|
      next if @release_checkpoints.key?(candidate)

      prepare_release_repository(candidate)
      commit = git!("rev-parse", "HEAD").strip
      tree = git!("rev-parse", "HEAD^{tree}").strip
      result = if @real_release_artifacts
        Dir.mktmpdir("hitch-release-evidence-built-") do |destination|
          HitchReleaseArtifact.rebuild!(
            root: @root,
            commit:,
            version: candidate,
            destination:,
            expected_tree: tree
          )
        end
      else
        {
          "artifact" => "hitch-rails-#{candidate}.gem",
          "sha256" => Digest::SHA256.hexdigest("fixture artifact #{candidate} #{commit} #{tree}")
        }
      end
      @release_checkpoints[candidate] = {
        "version" => candidate,
        "status" => "accepted_internal_checkpoint",
        "source_commit" => commit,
        "source_tree" => tree,
        "artifact" => result.fetch("artifact"),
        "sha256" => result.fetch("sha256")
      }
    end
  end

  def prepare_release_repository(version)
    unless File.directory?(File.join(@root, ".git"))
      FileUtils.mkdir_p(File.join(@root, "lib/hitch"))
      FileUtils.mkdir_p(File.join(@root, "docs/contracts"))
      File.write(File.join(@root, "docs/contracts/mcp_public_api.yml"), <<~YAML)
        schema_version: 1
        release: 0.2.0
        entries:
          - name: Hitch::MCP::Endpoint
            reload_behavior: Resolves configured registry class by name on each request.
      YAML
      File.write(File.join(@root, "hitch-rails.gemspec"), <<~RUBY)
        require_relative "lib/hitch/version"

        Gem::Specification.new do |spec|
          spec.name = "hitch-rails"
          spec.version = Hitch::VERSION
          spec.authors = [ "Hitch Test" ]
          spec.summary = "Hitch release evidence fixture"
          spec.files = [ "lib/hitch/version.rb" ]
          spec.require_paths = [ "lib" ]
        end
      RUBY
      git!("init", "--quiet")
      git!("config", "user.name", "Hitch Test")
      git!("config", "user.email", "hitch-test@example.com")
      File.write(File.join(@root, "lib/hitch/version.rb"), <<~RUBY)
        module Hitch
          VERSION = "0.2.0.pre.4"
        end
      RUBY
      git!("add", ".")
      git!("commit", "--quiet", "-m", "Release 0.2.0.pre.4")
      rebind_pre4_decision!
    end

    FileUtils.mkdir_p(File.join(@root, ".github/workflows"))
    if version == "0.2.0.rc1"
      api_path = File.join(@root, "docs/contracts/mcp_public_api.yml")
      api = YAML.safe_load_file(api_path, permitted_classes: [], aliases: false)
      endpoint = api.fetch("entries").find { |entry| entry.fetch("name") == "Hitch::MCP::Endpoint" }
      endpoint["reload_behavior"] = M6_PUBLIC_API_ERRATUM.fetch("corrected")
      api["errata"] = [ M6_PUBLIC_API_ERRATUM ]
      File.write(api_path, YAML.dump(api))
    end
    File.write(File.join(@root, ".github/workflows/ci.yml"), <<~YAML)
      name: CI
      on: [push]
      jobs:
        supported-matrix:
          runs-on: ubuntu-latest
          steps:
            - run: bin/ci
    YAML
    File.write(File.join(@root, "lib/hitch/version.rb"), <<~RUBY)
      module Hitch
        VERSION = "#{version}"
      end
    RUBY
    git!("add", ".")
    git!("commit", "--quiet", "-m", "Release #{version}")
  end

  def rebind_pre4_decision!
    decision = JSON.parse(File.read(File.join(@root, DECISION_PATH)))
    decision.fetch("checkpoint").fetch("source")["commit"] = git!("rev-parse", "HEAD").strip
    decision.fetch("checkpoint").fetch("source")["tree"] = git!("rev-parse", "HEAD^{tree}").strip
    write_json(DECISION_PATH, decision)
    record_for("pre4_publication_decision")["sha256"] =
      Digest::SHA256.file(File.join(@root, DECISION_PATH)).hexdigest
    save_index
  end

  def m6_public_api_proof
    rc1 = checkpoint("0.2.0.rc1")
    decision = JSON.parse(File.read(File.join(@root, DECISION_PATH)))
    input_commit = decision.dig("checkpoint", "source", "commit")
    path = "docs/contracts/mcp_public_api.yml"
    input_sha = Digest::SHA256.hexdigest(git!("show", "#{input_commit}:#{path}"))
    checkpoint_sha = Digest::SHA256.hexdigest(git!("show", "#{rc1.fetch('source_commit')}:#{path}"))
    {
      "path" => path,
      "input_source_commit" => input_commit,
      "input_sha256" => input_sha,
      "checkpoint_source_commit" => rc1.fetch("source_commit"),
      "checkpoint_sha256" => checkpoint_sha,
      "unchanged" => input_sha == checkpoint_sha,
      "documentation_errata" => input_sha == checkpoint_sha ? [] : [ M6_PUBLIC_API_ERRATUM.fetch("id") ]
    }
  end

  def git!(*arguments)
    output, status = Open3.capture2e("git", *arguments, chdir: @root)
    raise output unless status.success?

    output
  end

  def final_artifact
    release = checkpoint("0.2.0")
    {
      "version" => "0.2.0",
      "artifact" => "hitch-rails-0.2.0.gem",
      "sha256" => release.fetch("sha256")
    }
  end

  def final_prerequisites
    contract = YAML.safe_load_file(File.join(@root, CONTRACT_PATH), permitted_classes: [], aliases: false)
    kinds = (
      contract.fetch("accepted_records").keys +
        # Reopened by the M4.3 erratum; still required before final 0.2.0.
        %w[rate_limit_cross_process] +
        %w[copied_lineage independent product_clients hosted_matrix final_local_gates]
    ).sort
    kinds.map do |kind|
      record = record_for(kind)
      { "kind" => kind, "path" => record.fetch("path"), "sha256" => record.fetch("sha256") }
    end
  end

  def not_applicable_rerun
    {
      "status" => "not_applicable",
      "host" => nil,
      "command" => nil,
      "source_commit" => nil,
      "source_tree" => nil,
      "artifact_sha256" => nil,
      "verified_at" => nil,
      "report_sha256" => nil
    }
  end

  def passed_rerun(host:, checkpoint:, verified_at:, report_sha256:)
    {
      "status" => "passed",
      "host" => host,
      "command" => "reviewed #{host} output-checkpoint rerun",
      "source_commit" => checkpoint.fetch("source_commit"),
      "source_tree" => checkpoint.fetch("source_tree"),
      "artifact_sha256" => checkpoint.fetch("sha256"),
      "verified_at" => verified_at,
      "report_sha256" => report_sha256
    }
  end

  def evidence_gates(
    names,
    external: [],
    external_report_sha256: nil,
    linked_evidence: {},
    local_bundle_kind: nil,
    milestone_local_reports: {}
  )
    names.index_with do |name|
      linked_kind = linked_evidence[name]
      local_bundle_gate = local_bundle_kind && !external.include?(name)
      milestone_local_report = milestone_local_reports[name]
      report_sha256 = if linked_kind
        record_for(linked_kind).fetch("sha256")
      elsif local_bundle_gate
        record_for(local_bundle_kind).fetch("sha256")
      elsif milestone_local_report
        Digest::SHA256.hexdigest("#{JSON.pretty_generate(milestone_local_report)}\n")
      elsif external.include?(name) && external_report_sha256
        external_report_sha256
      else
        Digest::SHA256.hexdigest("#{name} release gate report")
      end
      gate = {
        "status" => "passed",
        "verification" => external.include?(name) ? "operator_reviewed_external" : "automated_local",
        "command" => milestone_local_report ? milestone_local_report.fetch("command") : local_bundle_gate ?
          HitchFinalLocalGates.command_label(HitchFinalLocalGates::COMMANDS.fetch(name)) :
          "release-gate #{name.tr('_', '-')}",
        "report_sha256" => report_sha256
      }
      if local_bundle_gate
        gate["report_kind"] = local_bundle_kind
        gate["report_gate"] = name
      end
      gate["report"] = milestone_local_report if milestone_local_report
      gate
    end
  end

  def milestone_local_report(milestone, gate, candidate)
    started_at, completed_at = if milestone == "M6"
      %w[2026-08-03T00:40:00Z 2026-08-03T00:50:00Z]
    else
      %w[2026-08-03T01:40:00Z 2026-08-03T01:50:00Z]
    end
    contract = MILESTONE_LOCAL_GATES.fetch(milestone).fetch(gate)
    {
      "schema" => MILESTONE_LOCAL_GATE_SCHEMA,
      "milestone" => milestone,
      "gate" => gate,
      "status" => "passed",
      "started_at" => started_at,
      "completed_at" => completed_at,
      "command" => contract.fetch("command"),
      "candidate" => candidate.slice(
        "version", "artifact", "sha256", "source_commit", "source_tree"
      ).merge("clean_worktree" => true),
      "command_output_sha256" => Digest::SHA256.hexdigest("#{milestone} #{gate} output"),
      "structured_report_sha256" => contract.fetch("structured_report") ?
        Digest::SHA256.hexdigest("#{milestone} #{gate} structured report") : nil
    }
  end

  def redaction
    {
      "contains_credentials" => false,
      "contains_private_logs" => false,
      "contains_customer_data" => false,
      "contains_private_repository_paths" => false
    }
  end

  def write_json(relative_path, value)
    path = File.join(@root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(value)}\n")
  end
end
