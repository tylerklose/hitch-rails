# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

class VerifyDocContractTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  VERIFIER = REPOSITORY_ROOT.join("bin/verify-doc-contract").to_s

  setup do
    @root = Dir.mktmpdir("hitch-doc-contract")
    FileUtils.mkdir_p(File.join(@root, "docs"))
    %w[adr architecture contracts security].each do |directory|
      FileUtils.cp_r(REPOSITORY_ROOT.join("docs", directory), File.join(@root, "docs", directory))
    end
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  test "accepts the frozen document contract" do
    _stdout, stderr, status = run_verifier
    assert_predicate status, :success?, stderr
  end

  test "rejects an incomplete public API entry" do
    mutate_yaml("docs/contracts/mcp_public_api.yml") do |document|
      document.fetch("entries").first.delete("errors")
    end

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "errors is missing"
  end

  test "rejects a sensitive or changed event payload" do
    mutate_yaml("docs/contracts/mcp_public_api.yml") do |document|
      event = document.fetch("entries").find { |entry| entry["name"] == "request.hitch_mcp" }
      event.fetch("payload_keys") << "arguments"
    end

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "sensitive event keys arguments"
    assert_includes stderr, "exact payload key set differs"
  end

  test "rejects an invariant without mutation or killing tests" do
    mutate_yaml("docs/contracts/mcp_invariants.yml") do |document|
      invariant = document.fetch("invariants").first
      invariant["mutation"] = ""
      invariant["killing_tests"] = []
    end

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "mutation vector is missing"
    assert_includes stderr, "killing tests are missing"
  end

  test "rejects a missing SDK issue link or probe" do
    path = File.join(@root, "docs/contracts/sdk_probes.yml")
    content = File.read(path).gsub("https://github.com/modelcontextprotocol/ruby-sdk/issues/389", "https://example.invalid/389")
    File.write(path, content.sub(/  - id: structural_symbol_keys\n.*?(?=  - id: selective_argument_symbolization)/m, ""))

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "required probe set differs"
    assert_includes stderr, "missing upstream issue link"
  end

  test "rejects an ADR without a decision" do
    path = File.join(@root, "docs/adr/0002-registry-and-reload.md")
    File.write(path, File.read(path).sub("## Decision", "## Choice"))

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "missing ## Decision"
  end

  private

  def run_verifier
    Open3.capture3(RbConfig.ruby, VERIFIER, "--root", @root)
  end

  def mutate_yaml(relative_path)
    path = File.join(@root, relative_path)
    document = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
    yield document
    File.write(path, YAML.dump(document))
  end
end
