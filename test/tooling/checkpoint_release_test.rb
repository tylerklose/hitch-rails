# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../../tooling/checkpoint_release"

class CheckpointReleaseTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("hitch-checkpoint-release-root")
    @outside = Dir.mktmpdir("hitch-checkpoint-release-outside")
    build_repository
    write_evidence
  end

  teardown do
    FileUtils.remove_entry(@root) if File.exist?(@root)
    FileUtils.remove_entry(@outside) if File.exist?(@outside)
  end

  test "loads and stages every accepted internal checkpoint from indexed evidence" do
    HitchCheckpointRelease::CHECKPOINTS.each_key do |version|
      record = HitchCheckpointRelease.candidate!(root: @root, version:)
      candidate = record.fetch("candidate")
      expected = @checkpoints.fetch(version)

      assert_equal expected, candidate
      assert_match(%r{\Adocs/evidence/0\.2\.0/}, record.fetch("evidence_path"))
      Dir.mktmpdir("hitch-checkpoint-stage-") do |destination|
        result = HitchCheckpointRelease.stage!(root: @root, candidate:, destination:)
        assert_equal expected.fetch("sha256"), Digest::SHA256.file(result.fetch("artifact_path")).hexdigest
        assert_equal "internal_checkpoint", result.dig("validation", "public_contract")
      end
    end
  end

  test "rejects a pending checkpoint and a public checkpoint status" do
    update_index("copied_lineage", status: "pending", sha256: nil)
    error = assert_raises(HitchCheckpointRelease::VerificationError) do
      HitchCheckpointRelease.candidate!(root: @root, version: "0.2.0.rc1")
    end
    assert_includes error.message, "not accepted"

    write_evidence
    path = evidence_path("independent")
    evidence = JSON.parse(File.binread(path))
    evidence.fetch("checkpoint")["status"] = "accepted_public_checkpoint"
    write_json(path, evidence)
    update_index("independent", sha256: Digest::SHA256.file(path).hexdigest)
    error = assert_raises(HitchCheckpointRelease::VerificationError) do
      HitchCheckpointRelease.candidate!(root: @root, version: "0.2.0.rc2")
    end
    assert_includes error.message, "must be accepted and internal"
  end

  test "preserves an existing staged checkpoint" do
    candidate = HitchCheckpointRelease.candidate!(root: @root, version: "0.2.0.pre.4").fetch("candidate")
    target = File.join(@outside, candidate.fetch("artifact"))
    File.binwrite(target, "operator artifact")

    error = assert_raises(HitchCheckpointRelease::VerificationError) do
      HitchCheckpointRelease.stage!(root: @root, candidate:, destination: @outside)
    end

    assert_includes error.message, "already exists"
    assert_equal "operator artifact", File.binread(target)
  end

  private

  def build_repository
    required = HitchFinalRelease::REQUIRED_FILES
    required.each do |relative_path|
      path = File.join(@root, relative_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{relative_path}\n")
    end
    File.write(File.join(@root, "hitch-rails.gemspec"), <<~RUBY)
      require_relative "lib/hitch/version"
      Gem::Specification.new do |spec|
        spec.name = "hitch-rails"
        spec.version = Hitch::VERSION
        spec.authors = [ "Hitch Test" ]
        spec.summary = "Internal Hitch checkpoint"
        spec.description = "Internal Hitch checkpoint"
        spec.files = #{required.inspect}
        spec.require_paths = [ "lib" ]
      end
    RUBY
    git!("init", "--quiet")
    git!("config", "user.name", "Hitch Test")
    git!("config", "user.email", "hitch-test@example.com")

    @checkpoints = {}
    HitchCheckpointRelease::CHECKPOINTS.each_key do |version|
      File.write(File.join(@root, "lib/hitch/version.rb"), "module Hitch\n  VERSION = #{version.inspect}\nend\n")
      git!("add", ".")
      git!("commit", "--quiet", "-m", "Checkpoint #{version}")
      commit = git!("rev-parse", "HEAD").strip
      tree = git!("rev-parse", "HEAD^{tree}").strip
      built = Dir.mktmpdir("hitch-checkpoint-fixture-") do |destination|
        HitchReleaseArtifact.rebuild!(root: @root, commit:, version:, destination:, expected_tree: tree)
      end
      @checkpoints[version] = {
        "version" => version,
        "status" => "accepted_internal_checkpoint",
        "source_commit" => commit,
        "source_tree" => tree,
        "artifact" => built.fetch("artifact"),
        "sha256" => built.fetch("sha256")
      }
    end
  end

  def write_evidence
    pre4 = @checkpoints.fetch("0.2.0.pre.4")
    values = {
      "pre4_publication_decision" => {
        "decision" => "deferred_to_final",
        "checkpoint" => {
          "version" => pre4.fetch("version"),
          "status" => pre4.fetch("status"),
          "source" => {
            "commit" => pre4.fetch("source_commit"),
            "tree" => pre4.fetch("source_tree")
          },
          "artifact" => {
            "name" => pre4.fetch("artifact"),
            "sha256" => pre4.fetch("sha256")
          }
        }
      },
      "copied_lineage" => { "checkpoint" => @checkpoints.fetch("0.2.0.rc1") },
      "independent" => { "checkpoint" => @checkpoints.fetch("0.2.0.rc2") }
    }
    records = values.map do |kind, evidence|
      path = evidence_path(kind)
      write_json(path, evidence)
      {
        "kind" => kind,
        "path" => path.delete_prefix("#{@root}/"),
        "status" => "accepted",
        "sha256" => Digest::SHA256.file(path).hexdigest
      }
    end
    @index = { "records" => records }
    save_index
  end

  def evidence_path(kind)
    filename = {
      "pre4_publication_decision" => "release/pre4-publication-decision.json",
      "copied_lineage" => "adoption/copied-lineage.json",
      "independent" => "adoption/independent.json"
    }.fetch(kind)
    File.join(@root, "docs/evidence/0.2.0", filename)
  end

  def update_index(kind, **updates)
    @index.fetch("records").find { |record| record.fetch("kind") == kind }.merge!(updates.transform_keys(&:to_s))
    save_index
  end

  def save_index
    write_json(File.join(@root, HitchFinalRelease::INDEX_PATH), @index)
  end

  def write_json(path, value)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(value)}\n")
  end

  def git!(*arguments)
    output, status = Open3.capture2e("git", *arguments, chdir: @root)
    raise output unless status.success?

    output
  end
end
