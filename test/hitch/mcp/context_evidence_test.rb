# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "open3"

class Hitch::MCP::ContextEvidenceTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  EVIDENCE_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/context/sdk-handoff.json")
  READERS = %w[
    principal
    access_token
    scope
    granted_scopes
    client_id
    resource
    request_id
    remote_ip
    user_agent
    protocol_version
    meta
  ].freeze
  SOURCE_FILES = {
    "context_sha256" => "app/models/hitch/mcp/context.rb",
    "endpoint_sha256" => "app/controllers/concerns/hitch/mcp/endpoint.rb",
    "sdk_adapter_sha256" => "app/models/hitch/mcp/internal/sdk_adapter.rb",
    "context_test_sha256" => "test/hitch/mcp/context_test.rb",
    "sdk_contract_test_sha256" => "test/hitch/mcp/sdk_contract_test.rb"
  }.freeze

  setup do
    @evidence = JSON.parse(EVIDENCE_PATH.read)
    @source = @evidence.fetch("source")
  end

  test "evidence resolves to the immutable M3.1 implementation" do
    assert_equal "hitch.m3.1-context-evidence.v1", @evidence.fetch("schema")
    assert_equal "M3.1", @evidence.fetch("milestone")
    assert_equal "accepted_internal_context_boundary", @evidence.fetch("status")
    assert_equal true, @source.fetch("worktree_clean_at_run")

    commit = @source.fetch("commit")
    tree = @source.fetch("tree")
    assert_match(/\A[0-9a-f]{40}\z/, commit)
    assert_match(/\A[0-9a-f]{40}\z/, tree)
    assert_equal tree, git!("rev-parse", "#{commit}^{tree}").strip
    assert_predicate git_status("merge-base", "--is-ancestor", commit, "HEAD"), :success?
    assert_includes git!("show", "#{commit}:lib/hitch/version.rb"),
      %(VERSION = "#{@evidence.dig('artifact', 'version')}")
  end

  test "source checksums bind the public context and private handoff" do
    SOURCE_FILES.each do |evidence_key, path|
      source = git!("show", "#{@source.fetch('commit')}:#{path}")
      assert_equal @evidence.dig("checksums", evidence_key), Digest::SHA256.hexdigest(source), path
    end

    contract = @evidence.fetch("contract")
    assert_equal "Hitch::MCP::Context", contract.fetch("public_constant")
    assert_equal READERS, contract.fetch("readers")
    assert_equal %w[principal access_token scope], contract.fetch("opaque_request_local_references")
    assert_equal [ "hitch_context" ], contract.fetch("sdk_context_keys")
    assert_equal true, contract.fetch("sdk_context_exact_wrapper")
    assert_equal "server_context.fetch(:hitch_context)", contract.fetch("sdk_context_retrieval")
    assert_equal false, contract.fetch("sdk_request_meta_forwarded")
  end

  test "acceptance records both SDK lanes and the isolation boundary" do
    context = @evidence.dig("acceptance", "context")
    assert_equal [ 4, 104, 0, 0, 0 ],
      context.values_at("runs", "assertions", "failures", "errors", "skips")

    lanes = @evidence.dig("acceptance", "sdk_lanes")
    assert_equal %w[min latest], lanes.map { |lane| lane.fetch("name") }
    assert_equal [ "1.1.0" ], lanes.map { |lane| lane.fetch("resolved") }.uniq
    assert lanes.all? { |lane| lane.values_at("failures", "errors", "skips") == [ 0, 0, 0 ] }
    assert lanes.all? { |lane| lane.fetch("lock_sha256").match?(/\A[0-9a-f]{64}\z/) }

    isolation = @evidence.fetch("isolation_cases")
    assert_equal 2, isolation.fetch("simulated_principals")
    assert isolation.except("simulated_principals").values.all?(true)
  end

  test "evidence contains no credentials, bodies, or host records" do
    sensitive = @evidence.fetch("sensitive_data")
    assert sensitive.values.none?
    refute_match(/Bearer\s+[A-Za-z0-9_-]+/, EVIDENCE_PATH.read)
  end

  private

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
