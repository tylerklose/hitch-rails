# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require_relative "../../tooling/artifact_staging"

class ArtifactStagingTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("hitch-artifact-staging-root")
    @outside = Dir.mktmpdir("hitch-artifact-staging-outside")
    @candidate = {
      "version" => "0.2.0.rc1",
      "artifact" => "hitch-rails-0.2.0.rc1.gem",
      "sha256" => "a" * 64,
      "source_commit" => "b" * 40,
      "source_tree" => "c" * 40
    }
  end

  teardown do
    FileUtils.remove_entry(@root) if File.exist?(@root)
    FileUtils.remove_entry(@outside) if File.exist?(@outside)
  end

  test "publishes exact bytes only after postconditions pass" do
    callback_ran = false
    result = HitchArtifactStaging.stage!(
      root: @root,
      candidate: @candidate,
      destination: @outside,
      builder: fake_builder("checkpoint bytes"),
      validator: ->(**) { { "valid" => true } },
      before_publish: -> { callback_ran = true }
    )

    assert callback_ran
    assert_equal "checkpoint bytes", File.binread(result.fetch("artifact_path"))
    assert_equal({ "valid" => true }, result.fetch("validation"))
  end

  test "leaves no output when a source postcondition fails" do
    target = File.join(@outside, @candidate.fetch("artifact"))

    error = assert_raises(RuntimeError) do
      HitchArtifactStaging.stage!(
        root: @root,
        candidate: @candidate,
        destination: @outside,
        builder: fake_builder("unpublished bytes"),
        validator: ->(**) { { "valid" => true } },
        before_publish: -> { raise "source changed" }
      )
    end

    assert_includes error.message, "source changed"
    assert_not File.exist?(target)
  end

  test "never overwrites or removes a pre-existing destination" do
    target = File.join(@outside, @candidate.fetch("artifact"))
    File.binwrite(target, "operator bytes")

    error = assert_raises(HitchArtifactStaging::VerificationError) do
      HitchArtifactStaging.stage!(
        root: @root,
        candidate: @candidate,
        destination: @outside,
        builder: ->(**) { flunk("builder must not run") },
        validator: ->(**) { flunk("validator must not run") }
      )
    end

    assert_includes error.message, "already exists"
    assert_equal "operator bytes", File.binread(target)
  end

  private

  def fake_builder(bytes)
    lambda do |root:, commit:, version:, destination:, expected_tree:, expected_sha256:|
      assert_equal File.realpath(@root), root
      assert_equal @candidate.fetch("source_commit"), commit
      assert_equal @candidate.fetch("source_tree"), expected_tree
      assert_equal @candidate.fetch("sha256"), expected_sha256
      artifact = "hitch-rails-#{version}.gem"
      artifact_path = File.join(destination, artifact)
      File.binwrite(artifact_path, bytes)
      {
        "artifact" => artifact,
        "artifact_path" => artifact_path,
        "sha256" => expected_sha256,
        "commit" => commit,
        "tree" => expected_tree,
        "version" => version
      }
    end
  end
end
