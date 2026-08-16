# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../../tooling/final_release"

class FinalReleaseTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("hitch-final-release-repository")
    @outside = Dir.mktmpdir("hitch-final-release-output")
    build_repository
    @candidate = build_candidate
    write_evidence
  end

  teardown do
    FileUtils.remove_entry(@root) if File.exist?(@root)
    FileUtils.remove_entry(@outside) if File.exist?(@outside)
  end

  test "loads the indexed final check and separate publication authority" do
    ready = HitchFinalRelease.candidate!(root: @root, authority: false)
    authorized = HitchFinalRelease.candidate!(root: @root, authority: true)

    assert_equal @candidate, ready.fetch("candidate")
    assert_equal @candidate, authorized.fetch("candidate")
    assert_equal "docs/evidence/0.2.0/release/final-check.json", ready.fetch("evidence_path")
    assert_equal "docs/evidence/0.2.0/release/final-publication-authority.json",
      authorized.fetch("evidence_path")
    refute_equal ready.fetch("evidence_sha256"), authorized.fetch("evidence_sha256")
  end

  test "stages exact source-bound public bytes without overwriting" do
    result = HitchFinalRelease.stage!(root: @root, candidate: @candidate, destination: @outside)

    assert_equal @candidate.fetch("sha256"), result.fetch("sha256")
    assert_equal @candidate.fetch("source_commit"), result.fetch("commit")
    assert_equal @candidate.fetch("source_tree"), result.fetch("tree")
    assert_equal({ "files" => HitchFinalRelease::REQUIRED_FILES.length, "public_contract" => "match" },
      result.fetch("validation"))
    artifact_path = File.join(@outside, @candidate.fetch("artifact"))
    assert File.file?(artifact_path)
    original_bytes = File.binread(artifact_path)

    error = assert_raises(HitchFinalRelease::VerificationError) do
      HitchFinalRelease.stage!(root: @root, candidate: @candidate, destination: @outside)
    end
    assert_includes error.message, "already exists"
    assert File.file?(artifact_path)
    assert_equal original_bytes, File.binread(artifact_path)
  end

  test "refuses a repository destination and an internal-checkpoint package" do
    error = assert_raises(HitchFinalRelease::VerificationError) do
      HitchFinalRelease.stage!(root: @root, candidate: @candidate, destination: @root)
    end
    assert_includes error.message, "outside the repository"

    readme = File.join(@root, "README.md")
    File.write(readme, "There is no public RubyGems release yet\n")
    git!("add", "README.md")
    git!("commit", "--quiet", "-m", "Internal package fixture")
    bad = build_candidate
    error = assert_raises(HitchFinalRelease::VerificationError) do
      HitchFinalRelease.stage!(root: @root, candidate: bad, destination: @outside)
    end
    assert_includes error.message, "README has not crossed the public installation boundary"
    refute File.exist?(File.join(@outside, bad.fetch("artifact")))
  end

  test "rejects stale internal status variants in final public documents" do
    stale_documents = {
      "README.md" => "The 0.2 development surface remains current.\n",
      "SECURITY.md" => "No 0.2 artifact has been published.\n",
      "docs/public_api/0.2.0.md" => "The latest sealed internal checkpoint remains current.\n",
      "docs/upgrading/0.2.0.md" => "# Adopting the internal Hitch 0.2 framework\n"
    }

    stale_documents.each do |relative_path, stale_text|
      original = File.read(File.join(@root, relative_path))
      File.write(File.join(@root, relative_path), "#{original}\n#{stale_text}")
      git!("add", relative_path)
      git!("commit", "--quiet", "-m", "Stale #{relative_path}")
      bad = build_candidate

      error = assert_raises(HitchFinalRelease::VerificationError) do
        Dir.mktmpdir("hitch-final-release-stale-") do |destination|
          HitchFinalRelease.stage!(root: @root, candidate: bad, destination:)
        end
      end
      assert_match(/README|internal checkpoint|public support boundary|upgrading guide/, error.message)

      File.write(File.join(@root, relative_path), original)
      git!("add", relative_path)
      git!("commit", "--quiet", "-m", "Restore #{relative_path}")
    end
  end

  test "rejects stale current changelog roadmap and gem metadata" do
    cases = {
      "CHANGELOG.md" => [
        ->(value) { value.sub("## [Unreleased]\n\n", "## [Unreleased]\n\nInternal development build only.\n\n") },
        "changelog still has unreleased content"
      ],
      "ROADMAP.md" => [
        ->(value) { value.sub(HitchFinalRelease::ROADMAP_RELEASE_STATUS, "Status: not shipped behavior.") },
        "roadmap has not crossed the completed public boundary"
      ],
      "hitch-rails.gemspec" => [
        ->(value) { value.gsub("opinionated authenticated MCP framework for Rails", "0.2 development line") },
        "gem metadata still describes a development-only product"
      ]
    }

    cases.each do |relative_path, (transform, message)|
      path = File.join(@root, relative_path)
      original = File.read(path)
      File.write(path, transform.call(original))
      git!("add", relative_path)
      git!("commit", "--quiet", "-m", "Stale current #{relative_path}")
      bad = build_candidate

      error = assert_raises(HitchFinalRelease::VerificationError) do
        Dir.mktmpdir("hitch-final-release-current-") do |destination|
          HitchFinalRelease.stage!(root: @root, candidate: bad, destination:)
        end
      end
      assert_includes error.message, message

      File.write(path, original)
      git!("add", relative_path)
      git!("commit", "--quiet", "-m", "Restore current #{relative_path}")
    end
  end

  private

  def build_repository
    files = {
      "CHANGELOG.md" => "# Changelog\n\n## [Unreleased]\n\n## [0.2.0] - 2026-08-03\n",
      "README.md" => %(# Hitch\n\n**Public release 0.2.0.**\n\ngem "hitch-rails", "~> 0.2.0"\n\nFour-lane release matrix.\n),
      "ROADMAP.md" => "# Roadmap\n\n#{HitchFinalRelease::ROADMAP_RELEASE_STATUS}\n",
      "SECURITY.md" => "# Security\n\n| Version | Supported |\n| --- | --- |\n| `0.2.x` | ✅ |\n",
      "docs/public_api/0.2.0.md" => "# Hitch 0.2.0 public API\n\nStatus: public 0.2.0 release.\n",
      "docs/removing.md" => "# Removing Hitch\n",
      "docs/upgrading/0.2.0.md" => "# Upgrading to Hitch 0.2.0\n\nThis guide applies to the public hitch-rails 0.2.0 release.\n",
      "lib/hitch/version.rb" => "module Hitch\n  VERSION = \"0.2.0\"\nend\n"
    }
    files.each do |relative_path, content|
      path = File.join(@root, relative_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    File.write(File.join(@root, "hitch-rails.gemspec"), <<~RUBY)
      require_relative "lib/hitch/version"

      Gem::Specification.new do |spec|
        spec.name = "hitch-rails"
        spec.version = Hitch::VERSION
        spec.authors = [ "Hitch Test" ]
        spec.summary = "Hitch is an opinionated authenticated MCP framework for Rails"
        spec.description = "Hitch is an opinionated authenticated MCP framework for Rails with an explicit Registry."
        spec.files = #{files.keys.inspect}
        spec.require_paths = [ "lib" ]
      end
    RUBY
    git!("init", "--quiet")
    git!("config", "user.name", "Hitch Test")
    git!("config", "user.email", "hitch-test@example.com")
    git!("add", ".")
    git!("commit", "--quiet", "-m", "Final release fixture")
  end

  def build_candidate
    commit = git!("rev-parse", "HEAD").strip
    tree = git!("rev-parse", "HEAD^{tree}").strip
    result = Dir.mktmpdir("hitch-final-release-build-") do |destination|
      HitchReleaseArtifact.rebuild!(
        root: @root,
        commit:,
        version: "0.2.0",
        destination:,
        expected_tree: tree
      )
    end
    {
      "version" => "0.2.0",
      "artifact" => result.fetch("artifact"),
      "sha256" => result.fetch("sha256"),
      "source_commit" => commit,
      "source_tree" => tree,
      "tag" => "v0.2.0"
    }
  end

  def write_evidence
    paths = {
      "final_check" => "docs/evidence/0.2.0/release/final-check.json",
      "publication_authority" => "docs/evidence/0.2.0/release/final-publication-authority.json"
    }
    values = {
      "final_check" => { "release" => @candidate },
      "publication_authority" => { "candidate" => @candidate }
    }
    records = paths.map do |kind, relative_path|
      path = File.join(@root, relative_path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{JSON.pretty_generate(values.fetch(kind))}\n")
      {
        "kind" => kind,
        "path" => relative_path,
        "status" => "accepted",
        "sha256" => Digest::SHA256.file(path).hexdigest
      }
    end
    index_path = File.join(@root, HitchFinalRelease::INDEX_PATH)
    FileUtils.mkdir_p(File.dirname(index_path))
    File.write(index_path, "#{JSON.pretty_generate("records" => records)}\n")
  end

  def git!(*arguments)
    output, status = Open3.capture2e("git", *arguments, chdir: @root)
    raise output unless status.success?

    output
  end
end
