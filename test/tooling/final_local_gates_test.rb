# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "json"
require "open3"
require "stringio"
require "tmpdir"
require_relative "../../tooling/final_local_gates"

class FinalLocalGatesTest < ActiveSupport::TestCase
  setup do
    @parent = Dir.mktmpdir("hitch-final-local-gates-test-")
    @root = File.join(@parent, "repository")
    @reports = File.join(@parent, "reports")
    FileUtils.mkdir_p([ @root, @reports ])
    File.write(File.join(@root, "fixture.txt"), "final source\n")
    git!("init", "--quiet")
    git!("config", "user.name", "Hitch Test")
    git!("config", "user.email", "hitch-test@example.com")
    git!("add", ".")
    git!("commit", "--quiet", "-m", "Final source")
  end

  teardown do
    FileUtils.remove_entry(@parent) if @parent && File.exist?(@parent)
  end

  test "pins both authorization conformance profiles and server conformance" do
    assert_equal [
      [ "bin/conformance-auth", "--profile", "metadata" ],
      [ "bin/conformance-auth", "--profile", "resource-aware-grants" ],
      [ "bin/conformance-server" ]
    ], HitchFinalLocalGates::COMMANDS.fetch("conformance")
  end

  test "writes one candidate-bound report for the fixed successful gate set" do
    invocations = []
    executor = lambda do |root:, argv:, stream:, environment:|
      invocations << [ root, argv ]
      stream.puts("passed #{argv.join(' ')}")
      write_structured_report(environment, argv) if environment["HITCH_PACKAGE_REPORT"]
      {
        "exit_status" => 0,
        "output_sha256" => Digest::SHA256.hexdigest("output #{argv.join(' ')}")
      }
    end
    report_path = File.join(@reports, "final-local-gates.json")
    result = HitchFinalLocalGates.run!(
      root: @root,
      report_path:,
      executor:,
      clock: ticking_clock,
      stream: StringIO.new,
      artifact_builder: fake_artifact_builder,
      package_validator: ->(**) { }
    )

    assert_equal HitchFinalLocalGates::COMMANDS.values.flatten(1), invocations.map(&:last)
    assert_equal File.join(File.realpath(@reports), File.basename(report_path)), result.fetch("path")
    assert_equal Digest::SHA256.file(report_path).hexdigest, result.fetch("sha256")
    report = JSON.parse(File.read(report_path))
    assert_equal HitchFinalLocalGates::SCHEMA, report.fetch("schema")
    assert_equal "hitch-rails-0.2.0.gem", report.dig("candidate", "artifact")
    assert report.dig("candidate", "clean_worktree")
    assert_equal HitchFinalLocalGates::COMMANDS.keys, report.fetch("gates").keys
    report.fetch("gates").each do |name, gate|
      assert_equal HitchFinalLocalGates::COMMANDS.fetch(name), gate.fetch("argv")
      assert_equal Array.new(gate.fetch("argv").length, 0), gate.fetch("exit_statuses")
      expected_command_hashes = gate.fetch("argv").map do |argv|
        Digest::SHA256.hexdigest("output #{argv.join(' ')}")
      end
      assert_equal expected_command_hashes, gate.fetch("command_output_sha256s")
      expected_report_count = %w[package_apps automated_clients].include?(name) ? 1 : 0
      assert_equal expected_report_count, gate.fetch("structured_report_sha256s").length
      assert gate.fetch("structured_report_sha256s").all? { |digest| digest.match?(/\A[0-9a-f]{64}\z/) }
      assert_equal Digest::SHA256.hexdigest(JSON.generate(expected_command_hashes)), gate.fetch("output_sha256")
      assert_match(/\A[0-9a-f]{64}\z/, gate.fetch("output_sha256"))
    end
    assert_equal false, report.dig("redaction", "raw_outputs_retained")
  end

  test "fails closed without writing a report when one command fails" do
    invocations = 0
    executor = lambda do |**|
      invocations += 1
      {
        "exit_status" => invocations == 2 ? 1 : 0,
        "output_sha256" => "a" * 64
      }
    end
    report_path = File.join(@reports, "failed.json")

    error = assert_raises(HitchFinalLocalGates::VerificationError) do
      HitchFinalLocalGates.run!(
        root: @root,
        report_path:,
        executor:,
        clock: ticking_clock,
        stream: StringIO.new,
        artifact_builder: fake_artifact_builder,
        package_validator: ->(**) { }
      )
    end

    assert_includes error.message, "final local gate conformance failed"
    assert_not File.exist?(report_path)
    assert_equal 2, invocations
  end

  test "refuses a dirty source before building or executing" do
    File.write(File.join(@root, "fixture.txt"), "changed\n")
    artifact_called = false

    error = assert_raises(HitchFinalLocalGates::VerificationError) do
      HitchFinalLocalGates.run!(
        root: @root,
        report_path: File.join(@reports, "dirty.json"),
        executor: ->(**) { flunk("executor must not run") },
        artifact_builder: ->(**) { artifact_called = true },
        package_validator: ->(**) { }
      )
    end

    assert_includes error.message, "clean worktree"
    assert_not artifact_called
  end

  test "refuses a clean HEAD switch while the gates are running" do
    switched = false
    executor = lambda do |root:, argv:, stream:, environment:|
      write_structured_report(environment, argv) if environment["HITCH_PACKAGE_REPORT"]
      if !switched && argv == [ "bin/contract" ]
        File.write(File.join(root, "second.txt"), "second source\n")
        git!("add", ".")
        git!("commit", "--quiet", "-m", "Second source")
        switched = true
      end
      { "exit_status" => 0, "output_sha256" => "a" * 64 }
    end

    error = assert_raises(HitchFinalLocalGates::VerificationError) do
      HitchFinalLocalGates.run!(
        root: @root,
        report_path: File.join(@reports, "switched.json"),
        executor:,
        artifact_builder: fake_artifact_builder,
        package_validator: ->(**) { },
        stream: StringIO.new
      )
    end

    assert_includes error.message, "changed HEAD"
  end

  test "refuses a passing package report for different candidate bytes" do
    executor = lambda do |root:, argv:, stream:, environment:|
      write_structured_report(environment, argv, sha256: "c" * 64) if environment["HITCH_PACKAGE_REPORT"]
      { "exit_status" => 0, "output_sha256" => "a" * 64 }
    end

    error = assert_raises(HitchFinalLocalGates::VerificationError) do
      HitchFinalLocalGates.run!(
        root: @root,
        report_path: File.join(@reports, "wrong-candidate.json"),
        executor:,
        artifact_builder: fake_artifact_builder,
        package_validator: ->(**) { },
        stream: StringIO.new
      )
    end

    assert_includes error.message, "reported different candidate bytes"
  end

  test "default executor forces test mode and removes generic database authority" do
    original_database_url = ENV["DATABASE_URL"]
    original_rails_env = ENV["RAILS_ENV"]
    ENV["DATABASE_URL"] = "postgresql://production.example/application"
    ENV["RAILS_ENV"] = "production"
    stream = StringIO.new

    result = HitchFinalLocalGates.execute!(
      root: @root,
      argv: [ RbConfig.ruby, "-e", 'puts [ENV["RAILS_ENV"], ENV.key?("DATABASE_URL"), ENV.key?("SCHEMA")].join(":")' ],
      stream:
    )

    assert_equal 0, result.fetch("exit_status")
    assert_equal "test:false:false\n", stream.string
  ensure
    ENV["DATABASE_URL"] = original_database_url
    ENV["RAILS_ENV"] = original_rails_env
  end

  private

  def fake_artifact_builder
    lambda do |root:, commit:, version:, destination:, expected_tree:|
      assert_equal File.realpath(@root), root
      assert_equal git!("rev-parse", "HEAD").strip, commit
      assert_equal git!("rev-parse", "HEAD^{tree}").strip, expected_tree
      assert_equal "0.2.0", version
      {
        "artifact" => "hitch-rails-0.2.0.gem",
        "artifact_path" => File.join(destination, "hitch-rails-0.2.0.gem"),
        "sha256" => "b" * 64,
        "commit" => commit,
        "tree" => expected_tree,
        "version" => version
      }
    end
  end

  def write_structured_report(environment, argv, sha256: "b" * 64)
    path = environment.fetch("HITCH_PACKAGE_REPORT")
    surface = argv == [ "bin/package-apps" ] ? "package-apps" : "client-smokes --automated"
    report = {
      "command_surface" => surface,
      "artifact_version" => "0.2.0",
      "target_checkpoint" => "0.2.0",
      "checkpoint_sealed" => true,
      "development" => false,
      "artifact" => {
        "name" => "hitch-rails-0.2.0.gem",
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
    time = Time.utc(2026, 8, 3, 12, 0, 0)
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
