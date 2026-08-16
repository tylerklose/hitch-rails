# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module HitchArtifactStaging
  class VerificationError < StandardError; end

  module_function

  def stage!(root:, candidate:, destination:, builder:, validator:, before_publish: nil)
    root = File.realpath(root)
    destination = File.realpath(destination)
    raise VerificationError, "artifact destination must be an existing directory" unless File.directory?(destination)
    if destination == root || destination.start_with?("#{root}/")
      raise VerificationError, "artifact destination must be outside the repository"
    end

    version = candidate.fetch("version")
    artifact = candidate.fetch("artifact")
    expected_artifact = "hitch-rails-#{version}.gem"
    raise VerificationError, "artifact name is invalid" unless artifact == expected_artifact

    target = File.join(destination, artifact)
    if File.exist?(target) || File.symlink?(target)
      raise VerificationError, "artifact destination already exists"
    end

    Dir.mktmpdir("hitch-artifact-staging-") do |temporary|
      result = builder.call(
        root:,
        commit: candidate.fetch("source_commit"),
        version:,
        destination: temporary,
        expected_tree: candidate.fetch("source_tree"),
        expected_sha256: candidate.fetch("sha256")
      )
      raise VerificationError, "rebuilt artifact identity drifted" unless result.fetch("artifact") == artifact

      validation = validator.call(artifact: result.fetch("artifact_path"), version:)
      before_publish&.call
      publish_exclusively!(source: result.fetch("artifact_path"), target:)
      result.merge("artifact_path" => target, "validation" => validation).freeze
    end
  rescue Errno::ENOENT
    raise VerificationError, "artifact destination must be an existing directory"
  rescue KeyError => error
    raise VerificationError, "artifact candidate is incomplete: #{error.key}"
  end

  def publish_exclusively!(source:, target:)
    created = false
    File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |output|
      created = true
      File.open(source, "rb") { |input| IO.copy_stream(input, output) }
      output.flush
      output.fsync
    end
    target
  rescue Errno::EEXIST
    raise VerificationError, "artifact destination already exists"
  rescue StandardError
    FileUtils.rm_f(target) if created
    raise
  end
  private_class_method :publish_exclusively!
end
