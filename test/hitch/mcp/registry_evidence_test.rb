# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require "open3"

class Hitch::MCP::RegistryEvidenceTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  EVIDENCE_PATH = REPOSITORY_ROOT.join("docs/evidence/0.2.0/registry/reload-validation.json")
  INVALID_ENTRIES = %w[
    anonymous_tool
    non_tool_class
    missing_tool_constant
    missing_name
    blank_name
    slash_name
    unicode_name
    long_name
    missing_description
    blank_description
    invalid_description_type
    missing_input_schema
    non_object_schema_document
    invalid_schema_type
    wrong_schema_dialect
    external_ref
    unresolved_local_ref
    malformed_pattern
    excessive_depth
    excessive_bytes
    invalid_output_schema
    unsupported_annotation
    invalid_annotation_scalar
    duplicate_annotation_alias
    explicit_server_context
    referenced_server_context
    composed_server_context
    call_override
    missing_scopes
    empty_scopes
    malformed_scope
    duplicate_scopes
    unsupported_scope
    duplicate_tool_name
    missing_registry_constant
    non_registry_class
    non_exact_registry_name
  ].freeze
  TABLE_INVALID_ENTRIES = INVALID_ENTRIES.first(33).freeze
  SOURCE_FILES = {
    "registry_sha256" => "app/models/hitch/mcp/registry.rb",
    "tool_sha256" => "app/models/hitch/mcp/tool.rb",
    "configuration_sha256" => "lib/hitch/mcp/configuration.rb",
    "engine_sha256" => "lib/hitch/engine.rb",
    "registry_test_sha256" => "test/hitch/mcp/registry_test.rb",
    "registry_reload_test_sha256" => "test/hitch/mcp/registry_reload_test.rb"
  }.freeze

  setup do
    @evidence = JSON.parse(EVIDENCE_PATH.read)
    @source = @evidence.fetch("source")
  end

  test "evidence resolves to the immutable M3.2 implementation" do
    assert_equal "hitch.m3.2-registry-evidence.v1", @evidence.fetch("schema")
    assert_equal "M3.2", @evidence.fetch("milestone")
    assert_equal "accepted_internal_registry_boundary", @evidence.fetch("status")
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

  test "source checksums bind class-name-only atomic registry code" do
    SOURCE_FILES.each do |evidence_key, path|
      source = git!("show", "#{@source.fetch('commit')}:#{path}")
      assert_equal @evidence.dig("checksums", evidence_key), Digest::SHA256.hexdigest(source), path
    end

    contract = @evidence.fetch("registry_contract")
    assert_equal %w[tool_class_name static_oauth_scopes], contract.fetch("declaration_storage")
    assert_equal false, contract.fetch("stores_class_objects")
    assert_equal "whole_snapshot_only", contract.fetch("publish_mode")
    assert_equal "raise_and_leave_unavailable", contract.fetch("failure_mode")
  end

  test "evidence names every invalid registry case" do
    assert_equal INVALID_ENTRIES, @evidence.fetch("invalid_entries")
    source = git!("show", "#{@source.fetch('commit')}:test/hitch/mcp/registry_test.rb")
    TABLE_INVALID_ENTRIES.each { |name| assert_includes source, "#{name}:" }
    assert_includes source, 'tool_name: "duplicate.name"'
    assert_includes source, 'registry = "MissingRegistry"'
    assert_includes source, "named_plain_class"
    assert_includes source, '"::#{plain.name}"'
  end

  test "snapshot and concurrency evidence preserve fail-closed transitions" do
    transitions = @evidence.fetch("snapshot_transitions")
    assert_equal 3, transitions.length
    assert_equal "unavailable_without_stale_snapshot", transitions.fetch(1).fetch("result")
    assert_equal "complete_new_snapshot_with_current_class_names", transitions.fetch(2).fetch("result")

    concurrency = @evidence.fetch("concurrency_results")
    assert_equal 2, concurrency.length
    assert concurrency.all? { |result| result.fetch("reader_during_prepare") == "waited_on_snapshot_lock" }
    assert_equal "received_same_complete_new_snapshot", concurrency.fetch(0).fetch("reader_after_prepare")
    assert_equal "received_unavailable_error_not_old_snapshot", concurrency.fetch(1).fetch("reader_after_prepare")
  end

  test "acceptance spans both Rails profiles without public distribution" do
    focused = @evidence.dig("acceptance", "focused_default")
    assert_equal [ 11, 397, 0, 0, 0 ],
      focused.values_at("runs", "assertions", "failures", "errors", "skips")

    profiles = @evidence.dig("acceptance", "rails_profiles")
    assert_equal %w[rails_7_2_sqlite rails_8_1_postgresql], profiles.map { |profile| profile.fetch("name") }
    assert profiles.all? { |profile| profile.values_at("failures", "errors", "skips") == [ 0, 0, 0 ] }
    assert profiles.all? { |profile| profile.fetch("eager_load") == "passed" }

    artifact = @evidence.fetch("artifact")
    assert_equal "internal_only", artifact.fetch("distribution")
    assert_equal false, artifact.fetch("published")
    assert_equal false, artifact.fetch("checkpoint_sealed")
    assert_includes @evidence.dig("acceptance", "package_smoke", "result"), "without_publication"
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
