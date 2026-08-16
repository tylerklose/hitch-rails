# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "rubygems/package"
require "tmpdir"

module HitchReleaseArtifact
  class VerificationError < StandardError; end

  SHA256 = /\A[0-9a-f]{64}\z/
  GIT_OBJECT = /\A[0-9a-f]{40}\z/

  module_function

  def rebuild!(root:, commit:, version:, destination:, expected_tree: nil, expected_sha256: nil)
    root = File.expand_path(root)
    destination = File.expand_path(destination)
    FileUtils.mkdir_p(destination)

    identity = source_identity!(root:, commit:)
    if expected_tree && identity.fetch("tree") != expected_tree
      raise VerificationError,
        "source tree differs: expected #{expected_tree}, got #{identity.fetch('tree')}"
    end

    Dir.mktmpdir("hitch-release-artifact-") do |temporary|
      archive = File.join(temporary, "source.tar")
      source = File.join(temporary, "source")
      FileUtils.mkdir_p(source)
      capture!("git", "archive", "--format=tar", "--output", archive, commit, chdir: root)
      capture!("tar", "-xf", archive, "-C", source, chdir: root)

      gemspec = File.join(source, "hitch-rails.gemspec")
      raise VerificationError, "source commit has no hitch-rails.gemspec" unless File.file?(gemspec)

      artifact_name = "hitch-rails-#{version}.gem"
      artifact = File.join(destination, artifact_name)
      capture!("gem", "build", gemspec, "--output", artifact, chdir: source)

      package = Gem::Package.new(artifact)
      specification = package.spec
      unless specification.name == "hitch-rails" && specification.version.to_s == version
        raise VerificationError,
          "rebuilt gem identity differs: expected hitch-rails #{version}, " \
          "got #{specification.name} #{specification.version}"
      end

      sha256 = Digest::SHA256.file(artifact).hexdigest
      if expected_sha256 && sha256 != expected_sha256
        raise VerificationError,
          "rebuilt gem SHA-256 differs: expected #{expected_sha256}, got #{sha256}"
      end

      identity.merge(
        "artifact" => artifact_name,
        "artifact_path" => artifact,
        "sha256" => sha256,
        "version" => version,
        "files" => package.contents.sort
      )
    end
  end

  def source_identity!(root:, commit:)
    raise VerificationError, "source commit must be 40 lowercase hex" unless commit.is_a?(String) && GIT_OBJECT.match?(commit)

    capture!("git", "cat-file", "-e", "#{commit}^{commit}", chdir: root)
    capture!("git", "merge-base", "--is-ancestor", commit, "HEAD", chdir: root)
    tree = capture!("git", "rev-parse", "#{commit}^{tree}", chdir: root).strip
    raise VerificationError, "resolved source tree is malformed" unless GIT_OBJECT.match?(tree)

    { "commit" => commit, "tree" => tree }
  end

  def capture!(*command, chdir:)
    output, status = Open3.capture2e(*command, chdir: chdir)
    return output if status.success?

    detail = output.strip
    suffix = detail.empty? ? "" : ": #{detail}"
    raise VerificationError, "#{command.join(' ')} failed#{suffix}"
  end
  private_class_method :capture!
end
