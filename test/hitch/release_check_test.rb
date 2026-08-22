# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

# bin/release-check runs once per release, by hand, against a gem that is
# already on RubyGems. Between releases nothing executes it, which is how a
# version of it that could only ever fail survived a whole release (#24).
#
# Nothing here can publish, so `gem fetch` is shimmed away. That is the only
# thing shimmed. The repository is real, the tag is annotated, the gems come
# out of `gem build`, and the gemspec-loaded-from-a-worktree step that #24
# broke runs for real — as does every comparison after it.
class Hitch::ReleaseCheckTest < ActiveSupport::TestCase
  TAG = "v#{Hitch::VERSION}"
  ARTIFACT = "hitch-rails-#{Hitch::VERSION}.gem"
  SMUGGLED = "lib/hitch/smuggled.rb"

  # A repository copy and three `gem build` runs, too slow to repeat per test.
  def self.fixture
    @fixture ||= Fixture.new
  end

  test "a publish that matches the tag passes" do
    output, status = release_check("published")

    assert_predicate status, :success?, output
    assert_includes output, "matches #{TAG}"
  end

  test "a published file rewritten after the tag fails, naming the file" do
    output, status = release_check("rewritten")

    refute_predicate status, :success?, "rewritten bytes must not pass:\n#{output}"
    assert_includes output, "published files differ from #{TAG}: README.md"
  end

  test "a file smuggled past the tag's allowlist fails on the manifest" do
    output, status = release_check("smuggled")

    refute_predicate status, :success?, "an unlisted file must not pass:\n#{output}"
    assert_includes output, "published manifest differs from the #{TAG} gemspec allowlist"
  end

  private

  def release_check(artifact)
    fixture = self.class.fixture

    Bundler.with_unbundled_env do
      Open3.capture2e(
        {
          "PATH" => "#{fixture.shim}#{File::PATH_SEPARATOR}#{ENV['PATH']}",
          "HITCH_RELEASE_CHECK_ARTIFACT" => fixture.artifact(artifact)
        },
        File.join(fixture.repository, "bin/release-check"), Hitch::VERSION,
        chdir: fixture.repository
      )
    end
  end

  # A throwaway repository holding this checkout's tracked files, tagged, with
  # one honest gem built from the tag and one gem per way of tampering.
  class Fixture
    attr_reader :repository, :shim

    def initialize
      @root = Dir.mktmpdir("hitch-release-check-test-")
      Minitest.after_run { FileUtils.remove_entry(@root, true) }
      @repository = File.join(@root, "repository")
      @shim = File.join(@root, "shim")
      FileUtils.mkdir_p(@repository)

      Bundler.with_unbundled_env do
        copy_tracked_files
        commit_and_tag
        build_gems
        write_shim
      end
    end

    def artifact(name)
      File.join(@root, name, ARTIFACT)
    end

    private

    # Tracked files only, and their working-tree contents: the gemspec
    # intersects its globs with `git ls-files`, so an untracked stray here
    # would change the manifest under test, and a copy from HEAD would test
    # the last committed script rather than the one on disk.
    def copy_tracked_files
      source = Hitch::Engine.root.to_s
      capture!("git", "-C", source, "ls-files", "-z").split("\x0").each do |path|
        destination = File.join(@repository, path)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(File.join(source, path), destination, preserve: true)
      end
    end

    def commit_and_tag
      git("init", "--quiet")
      # --force: a tracked file the checkout's own .gitignore matches would
      # otherwise be dropped here and silently vanish from the manifest.
      git("add", "--all", "--force")
      git("commit", "--quiet", "--message", "release-check fixture")
      git("tag", "--annotate", TAG, "--message", TAG)
    end

    def build_gems
      build("published")

      File.write(File.join(@repository, "README.md"), "\n<!-- rewritten after the tag -->\n", mode: "a")
      build("rewritten")
      git("checkout", "--", "README.md")

      File.write(File.join(@repository, SMUGGLED), "module Hitch; end\n")
      git("add", SMUGGLED)
      build("smuggled")
      git("rm", "--quiet", "--force", SMUGGLED)
    end

    def build(name)
      FileUtils.mkdir_p(File.dirname(artifact(name)))
      capture!("gem", "build", "hitch-rails.gemspec", "--output", artifact(name))
    end

    # Stands in for the network and refuses to stand in for anything else: a
    # new `gem` call in the script must fail loudly here, not be waved through.
    def write_shim
      FileUtils.mkdir_p(@shim)
      File.write(File.join(@shim, "gem"), <<~RUBY)
        #!/usr/bin/env ruby
        abort "release-check fixture: unexpected gem command \#{ARGV.inspect}" unless ARGV.first == "fetch"
        require "fileutils"
        FileUtils.cp(ENV.fetch("HITCH_RELEASE_CHECK_ARTIFACT"), Dir.pwd)
      RUBY
      FileUtils.chmod(0o755, File.join(@shim, "gem"))
    end

    def git(*arguments)
      capture!(
        "git",
        "-c", "user.name=Hitch", "-c", "user.email=hitch@example.com",
        "-c", "commit.gpgsign=false", "-c", "tag.gpgSign=false",
        *arguments
      )
    end

    def capture!(*command)
      output, status = Open3.capture2e(*command, chdir: @repository)
      raise "release-check fixture failed (#{command.join(' ')}):\n#{output}" unless status.success?

      output
    end
  end
end
