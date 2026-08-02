# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

class VerifyToolchainTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  VERIFIER = REPOSITORY_ROOT.join("bin/verify-toolchain").to_s

  setup do
    @root = Dir.mktmpdir("hitch-toolchain")
    %w[ROADMAP.md test/lattice/mcp_tool_authorization.json test/lattice/mcp_tool_authorization_scenarios.json test/conformance/toolchain.lock.yml test/conformance/expected-failures.yml].each do |relative_path|
      destination = File.join(@root, relative_path)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(REPOSITORY_ROOT.join(relative_path), destination)
    end
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  test "accepts exact pins and artifact hashes" do
    _stdout, stderr, status = run_verifier
    assert_predicate status, :success?, stderr
  end

  test "rejects contract artifact drift" do
    File.write(File.join(@root, "ROADMAP.md"), "drift")

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "checksum drift for ROADMAP.md"
  end

  test "rejects an SDK revision or missing lane" do
    mutate_lock do |lock|
      lock.fetch("ruby_sdk")["revision"] = "main"
      lock.fetch("ruby_sdk").fetch("lanes").delete("latest")
    end

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "exact v1.1.0 tag/revision pin is required"
    assert_includes stderr, "separately named min/latest lanes are required"
  end

  test "rejects a floating Redis image" do
    mutate_lock { |lock| lock.fetch("redis")["index_digest"] = "latest" }

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "immutable image index digest is required"
  end

  test "rejects any expected-failure drift" do
    path = File.join(@root, "test/conformance/expected-failures.yml")
    expected = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    expected.fetch("server") << "server-stateless:new-failure"
    File.write(path, YAML.dump(expected))

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "exact two-entry server baseline differs"
  end

  test "selected live binary version cannot be shadowed by an unrelated Ruby gem" do
    executable = File.join(@root, "fake-lattice")
    File.write(executable, <<~SH)
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        echo "lattice-cli 0.1.2"
      else
        echo '{"status":"ok","valid":true}'
      fi
    SH
    FileUtils.chmod(0o755, executable)

    _stdout, stderr, status = run_verifier({ "LATTICE_BIN" => executable }, "--live")
    assert_predicate status, :success?, stderr
  end

  private

  def run_verifier(environment = {}, *arguments)
    Open3.capture3(environment, RbConfig.ruby, VERIFIER, "--root", @root, *arguments)
  end

  def mutate_lock
    path = File.join(@root, "test/conformance/toolchain.lock.yml")
    lock = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    yield lock
    File.write(path, YAML.dump(lock))
  end
end
