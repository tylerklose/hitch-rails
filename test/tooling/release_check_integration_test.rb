# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "json"
require "open3"
require "rubygems/package"
require "tmpdir"
require_relative "../../tooling/release_artifact"

class ReleaseCheckIntegrationTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  RELEASE_CHECK = REPOSITORY_ROOT.join("bin/release-check").to_s

  setup do
    @parent = Dir.mktmpdir("hitch-release-check-integration-")
    @root = File.join(@parent, "repository")
    @artifacts = File.join(@parent, "artifacts")
    @fake_bin = File.join(@parent, "bin")
    @gate_log = File.join(@parent, "gate.log")
    FileUtils.mkdir_p([ @root, @artifacts, @fake_bin ])
    build_candidate_repository
    build_fake_gem_command
    build_fake_git_command
    write_postpublication_evidence
  end

  teardown do
    FileUtils.remove_entry(@parent) if @parent && File.exist?(@parent)
  end

  test "complete performs live verification reconciliation and a second ledger validation" do
    stdout, stderr, status = run_release_check

    assert_predicate status, :success?, stderr
    assert_includes stdout, "Live RubyGems bytes and v0.2.0 match"
    assert_equal [
      "verify-release-policy",
      "verify-release-evidence --complete 0.2.0",
      "verify-release-matrix",
      "verify-release-evidence --complete 0.2.0"
    ], File.readlines(@gate_log, chomp: true)
  end

  test "complete rejects a lightweight tag before fetching RubyGems bytes" do
    git!("tag", "-d", "v0.2.0")
    git!("tag", "v0.2.0", @candidate.fetch("source_commit"))

    _stdout, stderr, status = run_release_check

    assert_not status.success?
    assert_includes stderr, "must be an annotated tag"
    refute File.exist?(File.join(@parent, "fetch.log"))
  end

  test "complete rejects downloaded bytes that differ from the authorized candidate" do
    wrong = File.join(@artifacts, "wrong.gem")
    FileUtils.cp(@artifact_path, wrong)
    File.open(wrong, "ab") { |file| file.write("wrong bytes") }

    _stdout, stderr, status = run_release_check(fetch_artifact: wrong)

    assert_not status.success?
    assert_includes stderr, "downloaded RubyGems bytes differ from the explicitly authorized candidate"
  end

  test "complete rejects an annotated tag aimed at a different clean commit" do
    git!("tag", "-d", "v0.2.0")
    git!("tag", "-a", "v0.2.0", "-m", "Hitch 0.2.0", "HEAD")

    _stdout, stderr, status = run_release_check(
      remote_tag_object: git!("rev-parse", "refs/tags/v0.2.0").strip,
      remote_peeled_commit: git!("rev-parse", "v0.2.0^{commit}").strip
    )

    assert_not status.success?
    assert_includes stderr, "target differs from the explicitly authorized source commit/tree"
  end

  test "complete rejects a canonical remote tag object that differs from the local tag" do
    _stdout, stderr, status = run_release_check(remote_tag_object: "9" * 40)

    assert_not status.success?
    assert_includes stderr, "canonical remote tag object differs"
    refute File.exist?(File.join(@parent, "fetch.log"))
  end

  test "validate-version checks the worktree again after candidate staging" do
    _stdout, stderr, status = run_release_check(mode: "--validate-version", mutate_on_build: true)

    assert_not status.success?
    assert_includes stderr, "release check changed the worktree"
  end

  private

  def build_candidate_repository
    files = {
      "CHANGELOG.md" => "# Changelog\n\n## [Unreleased]\n\n## [0.2.0] - 2026-08-03\n",
      "README.md" => <<~MARKDOWN,
        # Hitch

        **Public release 0.2.0.**

        gem "hitch-rails", "~> 0.2.0"

        Four-lane release matrix.
      MARKDOWN
      "ROADMAP.md" => "# Roadmap\n\n> Status: completed for the public `0.2.0` release.\n",
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
    %w[verify-release-policy verify-release-evidence verify-release-matrix].each do |name|
      path = File.join(@root, "bin", name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, <<~RUBY)
        File.open(ENV.fetch("HITCH_TEST_GATE_LOG"), "a") do |file|
          file.puts(([#{name.inspect}] + ARGV).join(" "))
        end
      RUBY
    end
    git!("init", "--quiet")
    git!("config", "user.name", "Release Maintainer")
    git!("config", "user.email", "release@example.com")
    git!("add", ".")
    git!("commit", "--quiet", "-m", "Final candidate")

    commit = git!("rev-parse", "HEAD").strip
    tree = git!("rev-parse", "HEAD^{tree}").strip
    built = HitchReleaseArtifact.rebuild!(
      root: @root,
      commit:,
      version: "0.2.0",
      destination: @artifacts,
      expected_tree: tree
    )
    @artifact_path = built.fetch("artifact_path")
    @candidate = {
      "version" => "0.2.0",
      "artifact" => built.fetch("artifact"),
      "sha256" => built.fetch("sha256"),
      "source_commit" => commit,
      "source_tree" => tree,
      "tag" => "v0.2.0"
    }
    git!("tag", "-a", "v0.2.0", "-m", "Hitch 0.2.0", commit)
    @tag_object = git!("rev-parse", "refs/tags/v0.2.0").strip
  end

  def build_fake_gem_command
    path = File.join(@fake_bin, "gem")
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      require "fileutils"
      if ARGV.first == "fetch"
        source = ENV.fetch("HITCH_TEST_FETCH_GEM")
        FileUtils.cp(source, File.join(Dir.pwd, "hitch-rails-0.2.0.gem"))
        File.write(ENV.fetch("HITCH_TEST_FETCH_LOG"), "fetched\n")
        exit 0
      end

      if ARGV.first == "build" && ENV["HITCH_TEST_MUTATE_ON_BUILD"] == "1"
        File.write(ENV.fetch("HITCH_TEST_MUTATE_PATH"), "staging mutation\n")
      end
      exec ENV.fetch("HITCH_TEST_REAL_GEM"), *ARGV
    RUBY
    FileUtils.chmod(0o755, path)
  end

  def build_fake_git_command
    path = File.join(@fake_bin, "git")
    File.write(path, <<~'RUBY')
      #!/usr/bin/env ruby
      if ARGV.first == "ls-remote"
        reference = "refs/tags/v0.2.0"
        puts "#{ENV.fetch('HITCH_TEST_REMOTE_TAG_OBJECT')}\t#{reference}"
        puts "#{ENV.fetch('HITCH_TEST_REMOTE_PEELED_COMMIT')}\t#{reference}^{}"
        exit 0
      end
      exec ENV.fetch("HITCH_TEST_REAL_GIT"), *ARGV
    RUBY
    FileUtils.chmod(0o755, path)
  end

  def write_postpublication_evidence
    authority_path = "docs/evidence/0.2.0/release/final-publication-authority.json"
    downloaded_path = "docs/evidence/0.2.0/release/downloaded-gem.json"
    authority = { "candidate" => @candidate }
    write_json(authority_path, authority)
    authority_sha = Digest::SHA256.file(File.join(@root, authority_path)).hexdigest
    tag_metadata = git!(
      "for-each-ref",
      "--format=%(taggername)%00%(taggerdate:iso-strict)%00%(contents:subject)",
      "refs/tags/v0.2.0"
    ).strip.split("\0", 3)
    files = Gem::Package.new(@artifact_path).contents.length
    downloaded = {
      "schema" => "hitch.m8-downloaded-gem.v1",
      "milestone" => "M8",
      "release" => "0.2.0",
      "status" => "verified_published_artifact",
      "verified_at" => "2026-08-03T12:00:00Z",
      "publication_authority_sha256" => authority_sha,
      "rubygems" => {
        "artifact" => @candidate.fetch("artifact"),
        "sha256" => @candidate.fetch("sha256"),
        "files" => files
      },
      "repository" => {
        "tag" => "v0.2.0",
        "tag_type" => "tag",
        "tagger" => tag_metadata.fetch(0),
        "tagged_at" => tag_metadata.fetch(1),
        "annotation" => tag_metadata.fetch(2),
        "target_commit" => @candidate.fetch("source_commit"),
        "target_tree" => @candidate.fetch("source_tree"),
        "remote_url" => "https://github.com/tylerklose/hitch-rails.git",
        "remote_tag_object" => @tag_object,
        "remote_peeled_commit" => @candidate.fetch("source_commit")
      },
      "checks" => {
        "version" => "match",
        "manifest" => "match",
        "forbidden_paths" => "absent",
        "file_checksums" => "match",
        "readme" => "match",
        "changelog" => "match",
        "security" => "match",
        "upgrading" => "match",
        "public_api" => "match"
      }
    }
    write_json(downloaded_path, downloaded)
    records = {
      "publication_authority" => authority_path,
      "downloaded_gem" => downloaded_path
    }.map do |kind, relative_path|
      {
        "kind" => kind,
        "path" => relative_path,
        "status" => "accepted",
        "sha256" => Digest::SHA256.file(File.join(@root, relative_path)).hexdigest
      }
    end
    write_json("docs/evidence/0.2.0/index.json", "records" => records)
    git!("add", ".")
    git!("commit", "--quiet", "-m", "Accept postpublication evidence")
  end

  def run_release_check(
    fetch_artifact: @artifact_path,
    mode: "--complete",
    remote_tag_object: @tag_object,
    remote_peeled_commit: @candidate.fetch("source_commit"),
    mutate_on_build: false
  )
    real_git, git_status = Open3.capture2e("which", "git")
    raise real_git unless git_status.success?
    real_gem, gem_status = Open3.capture2e("which", "gem")
    raise real_gem unless gem_status.success?

    environment = {
      "PATH" => "#{@fake_bin}:#{ENV.fetch('PATH')}",
      "HITCH_TEST_FETCH_GEM" => fetch_artifact,
      "HITCH_TEST_FETCH_LOG" => File.join(@parent, "fetch.log"),
      "HITCH_TEST_GATE_LOG" => @gate_log,
      "HITCH_TEST_REAL_GEM" => real_gem.strip,
      "HITCH_TEST_REAL_GIT" => real_git.strip,
      "HITCH_TEST_REMOTE_TAG_OBJECT" => remote_tag_object,
      "HITCH_TEST_REMOTE_PEELED_COMMIT" => remote_peeled_commit,
      "HITCH_TEST_MUTATE_ON_BUILD" => mutate_on_build ? "1" : "0",
      "HITCH_TEST_MUTATE_PATH" => File.join(@root, "staging-mutation.txt")
    }
    Open3.capture3(
      environment,
      RbConfig.ruby,
      RELEASE_CHECK,
      "--root", @root,
      mode, "0.2.0"
    )
  end

  def write_json(relative_path, value)
    path = File.join(@root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(value)}\n")
  end

  def git!(*arguments)
    output, status = Open3.capture2e("git", *arguments, chdir: @root)
    raise output unless status.success?

    output
  end
end
