# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "json"
require "open3"
require "stringio"
require "tmpdir"
require_relative "../../tooling/milestone_local_gate"

class MilestoneLocalGateTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("hitch-milestone-gate-root")
    @reports = Dir.mktmpdir("hitch-milestone-gate-reports")
    File.write(File.join(@root, "fixture.txt"), "source\n")
    git!("init", "--quiet")
    git!("config", "user.name", "Hitch Test")
    git!("config", "user.email", "hitch-test@example.com")
    git!("add", ".")
    git!("commit", "--quiet", "-m", "Source")
  end

  teardown do
    FileUtils.remove_entry(@root) if File.exist?(@root)
    FileUtils.remove_entry(@reports) if File.exist?(@reports)
  end

  test "writes fixed candidate-bound M6 and M7 reports" do
    HitchMilestoneLocalGate::CONTRACTS.each do |milestone, gates|
      gates.each do |gate, contract|
        path = File.join(@reports, "#{milestone}-#{gate}.json")
        result = HitchMilestoneLocalGate.run!(
          root: @root,
          milestone:,
          gate:,
          report_path: path,
          executor: successful_executor,
          clock: ticking_clock,
          stream: StringIO.new,
          artifact_builder: fake_artifact_builder,
          package_validator: ->(**) { }
        )

        report = JSON.parse(File.binread(path))
        assert_equal HitchMilestoneLocalGate::SCHEMA, report.fetch("schema")
        assert_equal contract.fetch("argv").join(" "), report.fetch("command")
        assert_equal contract.fetch("version"), report.dig("candidate", "version")
        assert report.dig("candidate", "clean_worktree")
        assert_equal Digest::SHA256.file(path).hexdigest, result.fetch("sha256")
        if contract.fetch("structured_report")
          assert_match(/\A[0-9a-f]{64}\z/, report.fetch("structured_report_sha256"))
        else
          assert_nil report.fetch("structured_report_sha256")
        end
      end
    end
  end

  test "writes no report when the command or source postcondition fails" do
    failed_path = File.join(@reports, "failed.json")
    error = assert_raises(HitchMilestoneLocalGate::VerificationError) do
      HitchMilestoneLocalGate.run!(
        root: @root,
        milestone: "M7",
        gate: "mutation_mcp",
        report_path: failed_path,
        executor: ->(**) { { "exit_status" => 1, "output_sha256" => "a" * 64 } },
        stream: StringIO.new,
        artifact_builder: fake_artifact_builder,
        package_validator: ->(**) { }
      )
    end
    assert_includes error.message, "exited 1"
    assert_not File.exist?(failed_path)

    changed_path = File.join(@reports, "changed.json")
    executor = lambda do |root:, **|
      File.write(File.join(root, "changed.txt"), "changed\n")
      { "exit_status" => 0, "output_sha256" => "a" * 64 }
    end
    error = assert_raises(HitchMilestoneLocalGate::VerificationError) do
      HitchMilestoneLocalGate.run!(
        root: @root,
        milestone: "M7",
        gate: "mutation_mcp",
        report_path: changed_path,
        executor:,
        stream: StringIO.new,
        artifact_builder: fake_artifact_builder,
        package_validator: ->(**) { }
      )
    end
    assert_includes error.message, "changed the worktree"
    assert_not File.exist?(changed_path)
  end

  test "rejects a package report for different checkpoint bytes" do
    executor = lambda do |root:, argv:, environment:, **|
      write_package_report(environment.fetch("HITCH_PACKAGE_REPORT"), version: "0.2.0.rc1", sha256: "f" * 64)
      { "exit_status" => 0, "output_sha256" => Digest::SHA256.hexdigest(argv.join(" ")) }
    end

    error = assert_raises(HitchMilestoneLocalGate::VerificationError) do
      HitchMilestoneLocalGate.run!(
        root: @root,
        milestone: "M6",
        gate: "package_smoke",
        report_path: File.join(@reports, "wrong.json"),
        executor:,
        stream: StringIO.new,
        artifact_builder: fake_artifact_builder,
        package_validator: ->(**) { }
      )
    end

    assert_includes error.message, "different checkpoint bytes"
  end

  private

  def successful_executor
    lambda do |root:, argv:, environment:, **|
      if environment["HITCH_PACKAGE_REPORT"]
        version = HitchMilestoneLocalGate::CONTRACTS.dig("M6", "package_smoke", "version")
        write_package_report(environment.fetch("HITCH_PACKAGE_REPORT"), version:)
      end
      { "exit_status" => 0, "output_sha256" => Digest::SHA256.hexdigest(argv.join(" ")) }
    end
  end

  def fake_artifact_builder
    lambda do |root:, commit:, version:, destination:, expected_tree:|
      assert_equal File.realpath(@root), root
      artifact = "hitch-rails-#{version}.gem"
      artifact_path = File.join(destination, artifact)
      File.binwrite(artifact_path, "artifact")
      {
        "artifact" => artifact,
        "artifact_path" => artifact_path,
        "sha256" => "b" * 64,
        "commit" => commit,
        "tree" => expected_tree,
        "version" => version
      }
    end
  end

  def write_package_report(path, version:, sha256: "b" * 64)
    report = {
      "command_surface" => "package-apps",
      "artifact_version" => version,
      "target_checkpoint" => version,
      "checkpoint_sealed" => true,
      "development" => false,
      "artifact" => {
        "name" => "hitch-rails-#{version}.gem",
        "sha256" => sha256,
        "source_commit" => git!("rev-parse", "HEAD").strip,
        "source_tree" => git!("rev-parse", "HEAD^{tree}").strip,
        "checkout_clean" => true,
        "checkout_drift" => []
      }
    }
    File.write(path, "#{JSON.pretty_generate(report)}\n")
  end

  def ticking_clock
    time = Time.utc(2026, 8, 4, 12, 0, 0)
    lambda do
      value = time
      time += 1
      value
    end
  end

  def git!(*arguments)
    output, status = Open3.capture2e("git", *arguments, chdir: @root)
    raise output unless status.success?

    output
  end
end
