# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "time"
require "timeout"
require "tmpdir"
require_relative "exclusive_report"
require_relative "final_release"
require_relative "release_artifact"

module HitchFinalLocalGates
  COMMANDS = {
    "full_ci" => [ [ "bin/ci" ] ],
    "conformance" => [
      [ "bin/conformance-auth", "--profile", "metadata" ],
      [ "bin/conformance-auth", "--profile", "resource-aware-grants" ],
      [ "bin/conformance-server" ]
    ],
    "package_apps" => [ [ "bin/package-apps" ] ],
    "automated_clients" => [ [ "bin/client-smokes", "--automated" ] ],
    "mutation_mcp" => [ [ "bin/mutation-mcp" ] ],
    "documentation" => [ [ "bin/contract" ] ]
  }.freeze
  RELEASE = "0.2.0"
  SCHEMA = "hitch.m8-final-local-gates.v1"
  COMMAND_TIMEOUT_SECONDS = 1_800
  SANITIZED_ENVIRONMENT = {
    "RAILS_ENV" => "test",
    "DATABASE_URL" => nil,
    "SCHEMA" => nil
  }.freeze
  STRUCTURED_REPORT_GATES = {
    "package_apps" => "package-apps",
    "automated_clients" => "client-smokes --automated"
  }.freeze

  class VerificationError < StandardError; end

  module_function

  def command_label(argv_sets)
    argv_sets.map { |argv| argv.join(" ") }.join(" && ")
  end

  def run!(
    root:,
    report_path:,
    executor: method(:execute!),
    clock: -> { Time.now.utc },
    stream: $stdout,
    artifact_builder: HitchReleaseArtifact.method(:rebuild!),
    package_validator: HitchFinalRelease.method(:validate_package!)
  )
    root = File.realpath(root)
    before_status = git!(root, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    raise VerificationError, "final local gates require a clean worktree" unless before_status.empty?

    commit = git!(root, "rev-parse", "HEAD").strip
    tree = git!(root, "rev-parse", "HEAD^{tree}").strip
    artifact = Dir.mktmpdir("hitch-final-local-gates-") do |destination|
      result = artifact_builder.call(
        root:,
        commit:,
        version: RELEASE,
        destination:,
        expected_tree: tree
      )
      package_validator.call(artifact: result.fetch("artifact_path"), version: RELEASE)
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
    gates = execute_gates!(root:, executor:, clock:, stream:, candidate:)
    after_status = git!(root, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    raise VerificationError, "final local gates changed the worktree" unless after_status == before_status
    after_commit = git!(root, "rev-parse", "HEAD").strip
    raise VerificationError, "final local gates changed HEAD" unless after_commit == commit
    after_tree = git!(root, "rev-parse", "HEAD^{tree}").strip
    raise VerificationError, "final local gates changed the source tree" unless after_tree == tree

    report = {
      "schema" => SCHEMA,
      "milestone" => "M8",
      "status" => "accepted",
      "verified_at" => clock.call.utc.iso8601,
      "candidate" => candidate,
      "gates" => gates,
      "redaction" => {
        "contains_credentials" => false,
        "contains_private_logs" => false,
        "contains_customer_data" => false,
        "contains_private_repository_paths" => false,
        "raw_outputs_retained" => false
      }
    }
    bytes = "#{JSON.pretty_generate(report)}\n"
    destination = HitchExclusiveReport.write!(
      root:,
      path: report_path,
      bytes:,
      variable: "HITCH_FINAL_LOCAL_GATES_REPORT"
    )
    { "report" => report, "path" => destination, "sha256" => Digest::SHA256.hexdigest(bytes) }.freeze
  rescue HitchReleaseArtifact::VerificationError, HitchFinalRelease::VerificationError => error
    raise VerificationError, error.message
  end

  def execute_gates!(root:, executor:, clock:, stream:, candidate:)
    Dir.mktmpdir("hitch-final-local-reports-") do |report_directory|
      COMMANDS.to_h do |name, argv_sets|
        started_at = clock.call.utc.iso8601
        results = argv_sets.map.with_index do |argv, offset|
          stream.puts("==> #{argv.join(' ')}")
          report_path = if STRUCTURED_REPORT_GATES.key?(name)
            File.join(report_directory, "#{name}-#{offset + 1}.json")
          end
          environment = report_path ? { "HITCH_PACKAGE_REPORT" => report_path } : {}
          result = executor.call(root:, argv:, stream:, environment:)
          unless result.fetch("exit_status") == 0
            raise VerificationError, "final local gate #{name} failed: #{argv.join(' ')} exited #{result.fetch('exit_status')}"
          end
          if report_path
            result = result.merge(
              "structured_report_sha256" => validate_candidate_report!(
                path: report_path,
                gate: name,
                candidate:
              )
            )
          end
          result
        end
        completed_at = clock.call.utc.iso8601
        output_manifest = results.map { |result| result.fetch("output_sha256") }
        [
          name,
          {
            "argv" => argv_sets,
            "status" => "passed",
            "exit_statuses" => results.map { |result| result.fetch("exit_status") },
            "started_at" => started_at,
            "completed_at" => completed_at,
            "command_output_sha256s" => output_manifest,
            "structured_report_sha256s" => results.filter_map { |result| result["structured_report_sha256"] },
            "output_sha256" => Digest::SHA256.hexdigest(JSON.generate(output_manifest))
          }
        ]
      end
    end
  end

  def execute!(root:, argv:, stream:, environment: {})
    digest = Digest::SHA256.new
    stdin = output = wait_thread = reader = nil
    child_environment = SANITIZED_ENVIRONMENT.merge(environment)
    stdin, output, wait_thread = Open3.popen2e(child_environment, *argv, chdir: root, pgroup: true)
    stdin.close
    reader = Thread.new do
      loop do
        chunk = output.readpartial(16_384)
        digest.update(chunk)
        stream.write(chunk)
        stream.flush
      rescue EOFError
        break
      end
    end
    status = Timeout.timeout(COMMAND_TIMEOUT_SECONDS) { wait_thread.value }
    reader.join
    { "exit_status" => status.exitstatus, "output_sha256" => digest.hexdigest }.freeze
  rescue Timeout::Error
    terminate_process_group(wait_thread)
    reader&.join(5)
    raise VerificationError, "command timed out after #{COMMAND_TIMEOUT_SECONDS}s: #{argv.join(' ')}"
  ensure
    output&.close unless output&.closed?
  end

  def validate_candidate_report!(path:, gate:, candidate:)
    raise VerificationError, "final local gate #{gate} did not write its structured report" unless
      File.file?(path) && !File.symlink?(path)
    raise VerificationError, "final local gate #{gate} structured report is too large" if
      File.size(path) > 1_048_576

    report = JSON.parse(File.binread(path), allow_duplicate_key: false)
    raise VerificationError, "final local gate #{gate} structured report must be an object" unless report.is_a?(Hash)
    artifact = report.fetch("artifact")
    expected = {
      "name" => candidate.fetch("artifact"),
      "sha256" => candidate.fetch("sha256"),
      "source_commit" => candidate.fetch("source_commit"),
      "source_tree" => candidate.fetch("source_tree")
    }
    actual = artifact.slice(*expected.keys)
    raise VerificationError, "final local gate #{gate} reported different candidate bytes" unless actual == expected
    raise VerificationError, "final local gate #{gate} command surface drifted" unless
      report["command_surface"] == STRUCTURED_REPORT_GATES.fetch(gate)
    raise VerificationError, "final local gate #{gate} version drifted" unless
      report["artifact_version"] == candidate.fetch("version") &&
        report["target_checkpoint"] == candidate.fetch("version")
    raise VerificationError, "final local gate #{gate} did not test a sealed clean source" unless
      report["checkpoint_sealed"] == true && report["development"] == false &&
        artifact["checkout_clean"] == true && artifact["checkout_drift"] == []

    Digest::SHA256.file(path).hexdigest
  rescue JSON::ParserError, KeyError => error
    raise VerificationError, "final local gate #{gate} structured report is invalid: #{error.class}"
  end
  private_class_method :validate_candidate_report!

  def terminate_process_group(wait_thread)
    return unless wait_thread

    Process.kill("TERM", -wait_thread.pid)
    Timeout.timeout(5) { wait_thread.value }
  rescue Errno::ESRCH
    nil
  rescue Timeout::Error
    Process.kill("KILL", -wait_thread.pid)
    wait_thread.value
  end
  private_class_method :terminate_process_group

  def git!(root, *arguments)
    output, status = Open3.capture2e("git", *arguments, chdir: root)
    return output if status.success?

    raise VerificationError, "git #{arguments.join(' ')} failed"
  end
  private_class_method :git!
end
