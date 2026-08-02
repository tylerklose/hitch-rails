# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

class ReleasePolicyTest < ActiveSupport::TestCase
  VERIFIER = Rails.root.join("../../bin/verify-release-policy").expand_path.to_s
  CHECKPOINT_ROOT = "docs/evidence/0.1.0/checkpoint"

  setup do
    @root = Dir.mktmpdir("hitch-release-policy")
    write("docs/work_packets/index.yml", index_yaml)
    write(".github/workflows/ci.yml", "jobs:\n  checkpoint:\n    steps: []\n")
    write_json("#{CHECKPOINT_ROOT}/publication-status.json", publication_status)
    write_json("#{CHECKPOINT_ROOT}/completion.json", completion)
    write_json("#{CHECKPOINT_ROOT}/ci-matrix.json", ci_matrix)
    write_json("#{CHECKPOINT_ROOT}/package-manifest.json", package_manifest)
    write_json("#{CHECKPOINT_ROOT}/disposable-apps.json", { "status" => "green" })
    write_json("docs/evidence/0.1.0/auth/official-metadata.json", conformance(
      "official_unmodified_authorization_metadata"
    ))
    write_json("docs/evidence/0.1.0/auth/resource-aware-grants.json", conformance(
      "reviewed_resource_indicator_extension"
    ))
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  test "accepts an explicitly deferred internal candidate" do
    _stdout, stderr, status = run_verifier

    assert_predicate status, :success?, stderr
  end

  test "rejects an M0 publication claim" do
    update_json("#{CHECKPOINT_ROOT}/publication-status.json") do |evidence|
      evidence["published"] = true
    end

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "M0 publication must be false"
  end

  test "rejects public distribution before M5" do
    path = File.join(@root, "docs/work_packets/index.yml")
    File.write(path, File.read(path).sub(
      "distribution: internal_only",
      "distribution: public_optional"
    ))

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "M0.5 must own 0.1.0 as internal_only"
  end

  test "rejects an installable gem in public checkpoint CI" do
    write(".github/workflows/ci.yml", <<~YAML)
      jobs:
        checkpoint:
          steps:
            - uses: actions/upload-artifact@v7
              with:
                path: /tmp/hitch-rails-0.1.0.gem
    YAML

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "must not upload or retain an installable .gem"
  end

  test "preserves official and reviewed conformance classifications" do
    update_json("docs/evidence/0.1.0/auth/resource-aware-grants.json") do |evidence|
      evidence["classification"] = "official"
    end

    _stdout, stderr, status = run_verifier
    assert_not status.success?
    assert_includes stderr, "resource-aware extension classification drifted"
  end

  test "acceptance fails while exact lanes and immutable source are pending" do
    _stdout, stderr, status = run_verifier("--acceptance")

    assert_not status.success?
    assert_includes stderr, "both exact checkpoint lanes must be green"
    assert_includes stderr, "accepted checkpoint needs a 40-hex source commit"
  end

  test "acceptance passes only for one sealed green internal checkpoint" do
    source = {
      "commit" => "a" * 40,
      "tree" => "b" * 40,
      "clean_worktree" => true
    }
    update_json("#{CHECKPOINT_ROOT}/completion.json") do |evidence|
      evidence["status"] = "accepted_internal_checkpoint"
      evidence["accepted"] = true
      evidence["source"] = source
      evidence["gates"].transform_values! { "green" }
    end
    update_json("#{CHECKPOINT_ROOT}/ci-matrix.json") do |evidence|
      evidence["required_lanes"].each { |lane| lane["exact_result"] = { "result" => "green" } }
    end
    update_json("#{CHECKPOINT_ROOT}/package-manifest.json") do |evidence|
      evidence["status"] = "internal_checkpoint_verified"
      evidence["source_identity"] = source
    end

    _stdout, stderr, status = run_verifier("--acceptance")
    assert_predicate status, :success?, stderr
  end

  private

  def run_verifier(*arguments)
    Open3.capture3(RbConfig.ruby, VERIFIER, "--root", @root, *arguments)
  end

  def index_yaml
    <<~YAML
      schema_version: 2
      distribution_policy:
        first_public_eligible:
          issue: M5.4
          version: 0.2.0.pre.4
          decisions: [published_pre4, deferred_to_final]
        final_public_release:
          issue: M8
          version: 0.2.0
      nodes:
        M0.5:
          artifact: { version: 0.1.0, distribution: internal_only, verifier: bin/package-smoke }
        M2.3:
          artifact: { version: 0.2.0.pre.1, distribution: internal_only, verifier: bin/package-smoke }
        M3.3:
          artifact: { version: 0.2.0.pre.2, distribution: internal_only, verifier: bin/package-smoke }
        M4.5:
          artifact: { version: 0.2.0.pre.3, distribution: internal_only, verifier: bin/package-smoke }
        M5.4:
          creates_commands: [bin/release-check]
          artifact: { version: 0.2.0.pre.4, distribution: public_optional, verifier: bin/package-smoke, public_verifier: bin/release-check }
        M6:
          artifact: { version: 0.2.0.rc1, distribution: public_if_pre4_published, verifier: bin/package-smoke, public_verifier: bin/release-check }
        M7:
          artifact: { version: 0.2.0.rc2, distribution: public_if_pre4_published, verifier: bin/package-smoke, public_verifier: bin/release-check }
        M8:
          artifact: { version: 0.2.0, distribution: public_required, verifier: bin/package-smoke, public_verifier: bin/release-check }
    YAML
  end

  def publication_status
    {
      "status" => "intentionally_not_published",
      "published" => false,
      "rubygems_artifact" => nil,
      "rubygems_sha256" => nil,
      "repository_tag" => nil,
      "github_release" => nil,
      "next_public_eligible" => { "issue" => "M5.4", "version" => "0.2.0.pre.4" }
    }
  end

  def completion
    {
      "milestone" => "M0",
      "version" => "0.1.0",
      "status" => "candidate_not_accepted",
      "accepted" => false,
      "published" => false,
      "source" => { "commit" => nil, "tree" => nil, "clean_worktree" => false },
      "evidence" => {
        "ci_matrix" => "#{CHECKPOINT_ROOT}/ci-matrix.json",
        "package_manifest" => "#{CHECKPOINT_ROOT}/package-manifest.json",
        "disposable_apps" => "#{CHECKPOINT_ROOT}/disposable-apps.json",
        "publication_status" => "#{CHECKPOINT_ROOT}/publication-status.json"
      },
      "gates" => { "source" => "pending", "matrix" => "pending" }
    }
  end

  def ci_matrix
    {
      "required_lanes" => [
        { "exact_result" => { "result" => "pending" } },
        { "exact_result" => { "result" => "pending" } }
      ]
    }
  end

  def package_manifest
    {
      "status" => "internal_checkpoint_candidate_verified",
      "source_identity" => { "commit" => nil, "tree" => nil, "clean_worktree" => false }
    }
  end

  def conformance(classification)
    {
      "classification" => classification,
      "contains_credentials" => false,
      "raw_artifact" => "destroyed after every run and never uploaded"
    }
  end

  def update_json(relative_path)
    path = File.join(@root, relative_path)
    value = JSON.parse(File.read(path))
    yield value
    File.write(path, "#{JSON.pretty_generate(value)}\n")
  end

  def write_json(relative_path, value)
    write(relative_path, "#{JSON.pretty_generate(value)}\n")
  end

  def write(relative_path, content)
    path = File.join(@root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
