# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "time"
require "tmpdir"
require_relative "checkpoint_release"
require_relative "exclusive_report"
require_relative "final_local_gates"
require_relative "release_artifact"

module HitchMilestoneLocalGate
  SCHEMA = "hitch.milestone-local-gate.v1"
  CONTRACTS = {
    "M6" => {
      "package_smoke" => {
        "version" => "0.2.0.rc1",
        "argv" => [ "bin/package-smoke" ],
        "structured_report" => true
      }
    },
    "M7" => {
      "mutation_mcp" => {
        "version" => "0.2.0.rc2",
        "argv" => [ "bin/mutation-mcp" ],
        "structured_report" => false
      }
    }
  }.freeze
  SHA256 = /\A[0-9a-f]{64}\z/

  class VerificationError < StandardError; end

  module_function

  def run!(
    root:,
    milestone:,
    gate:,
    report_path:,
    executor: HitchFinalLocalGates.method(:execute!),
    clock: -> { Time.now.utc },
    stream: $stdout,
    artifact_builder: HitchReleaseArtifact.method(:rebuild!),
    package_validator: HitchCheckpointRelease.method(:validate_package!)
  )
    contract = CONTRACTS.dig(milestone, gate)
    raise VerificationError, "unsupported milestone local gate #{milestone}/#{gate}" unless contract

    root = File.realpath(root)
    before_status = git!(root, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    raise VerificationError, "milestone local gate requires a clean worktree" unless before_status.empty?
    commit = git!(root, "rev-parse", "HEAD").strip
    tree = git!(root, "rev-parse", "HEAD^{tree}").strip
    version = contract.fetch("version")
    artifact = Dir.mktmpdir("hitch-milestone-gate-artifact-") do |destination|
      result = artifact_builder.call(
        root:,
        commit:,
        version:,
        destination:,
        expected_tree: tree
      )
      package_validator.call(artifact: result.fetch("artifact_path"), version:)
      result.slice("artifact", "sha256", "commit", "tree", "version")
    end
    candidate = {
      "version" => artifact.fetch("version"),
      "artifact" => artifact.fetch("artifact"),
      "sha256" => artifact.fetch("sha256"),
      "source_commit" => artifact.fetch("commit"),
      "source_tree" => artifact.fetch("tree"),
      "clean_worktree" => true
    }

    started_at = clock.call.utc.iso8601
    result, structured_report_sha256 = execute_gate!(
      root:,
      milestone:,
      gate:,
      contract:,
      candidate:,
      executor:,
      stream:
    )
    completed_at = clock.call.utc.iso8601
    verify_source_unchanged!(root:, before_status:, commit:, tree:)

    report = {
      "schema" => SCHEMA,
      "milestone" => milestone,
      "gate" => gate,
      "status" => "passed",
      "started_at" => started_at,
      "completed_at" => completed_at,
      "command" => contract.fetch("argv").join(" "),
      "candidate" => candidate,
      "command_output_sha256" => result.fetch("output_sha256"),
      "structured_report_sha256" => structured_report_sha256
    }
    bytes = "#{JSON.pretty_generate(report)}\n"
    destination = HitchExclusiveReport.write!(
      root:,
      path: report_path,
      bytes:,
      variable: "HITCH_MILESTONE_LOCAL_GATE_REPORT"
    )
    { "report" => report, "path" => destination, "sha256" => Digest::SHA256.hexdigest(bytes) }.freeze
  rescue HitchReleaseArtifact::VerificationError, HitchCheckpointRelease::VerificationError,
    HitchFinalLocalGates::VerificationError => error
    raise VerificationError, error.message
  end

  def execute_gate!(root:, milestone:, gate:, contract:, candidate:, executor:, stream:)
    Dir.mktmpdir("hitch-milestone-gate-report-") do |directory|
      structured_path = contract.fetch("structured_report") ? File.join(directory, "package.json") : nil
      environment = structured_path ? { "HITCH_PACKAGE_REPORT" => structured_path } : {}
      argv = contract.fetch("argv")
      stream.puts("==> #{argv.join(' ')}")
      result = executor.call(root:, argv:, stream:, environment:)
      unless result.fetch("exit_status") == 0
        raise VerificationError, "#{milestone} local gate #{gate} failed: #{argv.join(' ')} exited #{result.fetch('exit_status')}"
      end
      output_sha256 = result.fetch("output_sha256")
      unless output_sha256.is_a?(String) && SHA256.match?(output_sha256)
        raise VerificationError, "#{milestone} local gate #{gate} output digest is invalid"
      end
      structured_sha256 = if structured_path
        validate_package_report!(path: structured_path, candidate:)
      end
      [ result, structured_sha256 ]
    end
  end
  private_class_method :execute_gate!

  def validate_package_report!(path:, candidate:)
    raise VerificationError, "M6 package smoke did not write its structured report" unless File.file?(path)

    report = JSON.parse(File.binread(path), allow_duplicate_key: false)
    artifact = report.fetch("artifact")
    unless report["command_surface"] == "package-apps" &&
        report["artifact_version"] == candidate.fetch("version") &&
        report["target_checkpoint"] == candidate.fetch("version") &&
        report["checkpoint_sealed"] == true && report["development"] == false &&
        artifact["name"] == candidate.fetch("artifact") &&
        artifact["sha256"] == candidate.fetch("sha256") &&
        artifact["source_commit"] == candidate.fetch("source_commit") &&
        artifact["source_tree"] == candidate.fetch("source_tree") &&
        artifact["checkout_clean"] == true && artifact["checkout_drift"] == []
      raise VerificationError, "M6 package smoke reported different checkpoint bytes or source"
    end

    Digest::SHA256.file(path).hexdigest
  rescue JSON::ParserError, KeyError => error
    raise VerificationError, "M6 package smoke report is invalid: #{error.class}"
  end
  private_class_method :validate_package_report!

  def verify_source_unchanged!(root:, before_status:, commit:, tree:)
    after_status = git!(root, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    raise VerificationError, "milestone local gate changed the worktree" unless after_status == before_status
    raise VerificationError, "milestone local gate changed HEAD" unless git!(root, "rev-parse", "HEAD").strip == commit
    raise VerificationError, "milestone local gate changed the source tree" unless
      git!(root, "rev-parse", "HEAD^{tree}").strip == tree
  end
  private_class_method :verify_source_unchanged!

  def git!(root, *arguments)
    output, status = Open3.capture2e("git", *arguments, chdir: root)
    return output if status.success?

    raise VerificationError, "git #{arguments.join(' ')} failed"
  end
  private_class_method :git!
end
