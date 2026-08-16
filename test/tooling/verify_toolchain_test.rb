# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

class VerifyToolchainTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  VERIFIER = REPOSITORY_ROOT.join("bin/verify-toolchain").to_s

  setup do
    @root = Dir.mktmpdir("hitch-toolchain")
    %w[ROADMAP.md test/lattice/mcp_tool_authorization.json test/lattice/mcp_tool_authorization_scenarios.json test/lattice/release_evidence.json test/lattice/release_evidence_scenarios.json test/lattice/m5_automated_clients.json test/lattice/m5_automated_clients_scenarios.json test/conformance/toolchain.lock.yml test/conformance/expected-failures.yml test/conformance/package.json test/conformance/package-lock.json test/conformance/harness.patch test/checkpoint/automated_clients.rb test/checkpoint/pinned_redis.rb test/clients/typescript/package.json test/clients/typescript/package-lock.json test/clients/typescript/smoke.mjs test/clients/python/requirements.lock test/clients/python/smoke.py].each do |relative_path|
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

  test "rejects release matrix artifact or metadata drift" do
    File.write(File.join(@root, "test/lattice/release_evidence_scenarios.json"), "{}")
    mutate_lock do |lock|
      lock.dig("contract", "release_lattice_scenarios")["expected_rows"] = 59
    end

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "checksum drift for test/lattice/release_evidence_scenarios.json"
    assert_includes stderr, "exhaustive strength 9, seed 42, and 60 rows are required"
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

  test "rejects a floating Redis image or gem range" do
    mutate_lock do |lock|
      lock.fetch("redis")["index_digest"] = "latest"
      lock.fetch("redis")["gem_requirement"] = ">= 5"
    end

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "immutable image index digest is required"
    assert_includes stderr, "exact >= 5, < 7 gem requirement is required"
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

  test "rejects local conformance lock or harness patch drift" do
    File.write(File.join(@root, "test/conformance/harness.patch"), "drift")

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "checksum drift for test/conformance/harness.patch"
  end

  test "rejects automated client fixture, matrix, or package lock drift" do
    File.write(File.join(@root, "test/clients/typescript/smoke.mjs"), "drift")
    File.write(File.join(@root, "test/checkpoint/pinned_redis.rb"), "drift")
    File.write(File.join(@root, "test/lattice/m5_automated_clients_scenarios.json"), "{}")

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "checksum drift for test/clients/typescript/smoke.mjs"
    assert_includes stderr, "checksum drift for test/checkpoint/pinned_redis.rb"
    assert_includes stderr, "checksum drift for test/lattice/m5_automated_clients_scenarios.json"
    assert_includes stderr, "invalid generated scenarios"
  end

  test "rejects an exact Python dependency without a hash" do
    path = File.join(@root, "test/clients/python/requirements.lock")
    content = File.read(path)
    content.sub!(/annotated-types==0\.8\.0 \\\n(?:    --hash=sha256:[0-9a-f]{64}(?: \\\n|\n))+/, "annotated-types==0.8.0\n")
    File.write(path, content)
    mutate_lock do |lock|
      lock.dig("automated_clients", "python", "requirements_lock")["sha256"] =
        Digest::SHA256.file(path).hexdigest
    end

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "every exact dependency must carry at least one SHA-256 hash"
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
