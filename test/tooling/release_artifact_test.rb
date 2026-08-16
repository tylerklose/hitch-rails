# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../../tooling/release_artifact"

class ReleaseArtifactTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("hitch-release-artifact-repository")
    @artifacts = Dir.mktmpdir("hitch-release-artifact-output")
    FileUtils.mkdir_p(File.join(@root, "lib/hitch"))
    File.write(File.join(@root, "lib/hitch/version.rb"), <<~RUBY)
      module Hitch
        VERSION = "0.2.0"
      end
    RUBY
    File.write(File.join(@root, "hitch-rails.gemspec"), <<~RUBY)
      require_relative "lib/hitch/version"

      Gem::Specification.new do |spec|
        spec.name = "hitch-rails"
        spec.version = Hitch::VERSION
        spec.authors = [ "Hitch Test" ]
        spec.summary = "Hitch release artifact fixture"
        spec.files = [ "lib/hitch/version.rb" ]
        spec.require_paths = [ "lib" ]
      end
    RUBY
    git!("init", "--quiet")
    git!("config", "user.name", "Hitch Test")
    git!("config", "user.email", "hitch-test@example.com")
    git!("add", ".")
    git!("commit", "--quiet", "-m", "Release fixture")
    @commit = git!("rev-parse", "HEAD").strip
    @tree = git!("rev-parse", "HEAD^{tree}").strip
  end

  teardown do
    FileUtils.remove_entry(@root) if @root && File.exist?(@root)
    FileUtils.remove_entry(@artifacts) if @artifacts && File.exist?(@artifacts)
  end

  test "rebuilds exact gem bytes from an ancestor commit and tree" do
    first = rebuild
    second = rebuild(expected_tree: @tree, expected_sha256: first.fetch("sha256"))

    assert_equal @commit, second.fetch("commit")
    assert_equal @tree, second.fetch("tree")
    assert_equal "hitch-rails-0.2.0.gem", second.fetch("artifact")
    assert_equal [ "lib/hitch/version.rb" ], second.fetch("files")
  end

  test "rejects nonexistent commits wrong trees hashes and versions" do
    error = assert_raises(HitchReleaseArtifact::VerificationError) do
      rebuild(commit: "f" * 40)
    end
    assert_includes error.message, "cat-file"

    error = assert_raises(HitchReleaseArtifact::VerificationError) do
      rebuild(expected_tree: "e" * 40)
    end
    assert_includes error.message, "source tree differs"

    error = assert_raises(HitchReleaseArtifact::VerificationError) do
      rebuild(expected_sha256: "d" * 64)
    end
    assert_includes error.message, "rebuilt gem SHA-256 differs"

    error = assert_raises(HitchReleaseArtifact::VerificationError) do
      rebuild(version: "0.2.0.rc2")
    end
    assert_includes error.message, "rebuilt gem identity differs"
  end

  private

  def rebuild(commit: @commit, version: "0.2.0", expected_tree: nil, expected_sha256: nil)
    HitchReleaseArtifact.rebuild!(
      root: @root,
      commit:,
      version:,
      destination: @artifacts,
      expected_tree:,
      expected_sha256:
    )
  end

  def git!(*arguments)
    output, status = Open3.capture2e("git", *arguments, chdir: @root)
    raise output unless status.success?

    output
  end
end
