# frozen_string_literal: true

require "rubygems/package"
require_relative "artifact_staging"
require_relative "final_release"
require_relative "release_artifact"

module HitchCheckpointRelease
  CHECKPOINTS = {
    "0.2.0.pre.4" => "pre4_publication_decision",
    "0.2.0.rc1" => "copied_lineage",
    "0.2.0.rc2" => "independent"
  }.freeze
  SHA256 = /\A[0-9a-f]{64}\z/
  COMMIT = /\A[0-9a-f]{40}\z/

  class VerificationError < StandardError; end

  module_function

  def candidate!(root:, version:)
    kind = CHECKPOINTS.fetch(version) do
      raise VerificationError, "unsupported internal checkpoint #{version.inspect}"
    end
    decision_record = HitchFinalRelease.accepted_evidence!(root:, kind: "pre4_publication_decision")
    decision = decision_record.fetch("evidence")
    unless decision["decision"] == "deferred_to_final"
      raise VerificationError, "internal checkpoint staging requires the deferred public train"
    end

    record = kind == "pre4_publication_decision" ? decision_record :
      HitchFinalRelease.accepted_evidence!(root:, kind:)
    checkpoint = checkpoint_from(record.fetch("evidence"), kind:)
    candidate = normalize_checkpoint(checkpoint, version:)
    {
      "candidate" => candidate,
      "evidence_path" => record.dig("record", "path"),
      "evidence_sha256" => record.dig("record", "sha256")
    }.freeze
  rescue HitchFinalRelease::VerificationError => error
    raise VerificationError, error.message
  end

  def stage!(root:, candidate:, destination:, before_publish: nil)
    HitchArtifactStaging.stage!(
      root:,
      candidate:,
      destination:,
      builder: HitchReleaseArtifact.method(:rebuild!),
      validator: method(:validate_package!),
      before_publish:
    )
  rescue HitchArtifactStaging::VerificationError, HitchReleaseArtifact::VerificationError => error
    raise VerificationError, error.message
  end

  def validate_package!(artifact:, version:)
    package = Gem::Package.new(artifact)
    specification = package.spec
    unless specification.name == HitchFinalRelease::GEM_NAME && specification.version.to_s == version
      raise VerificationError, "internal checkpoint gem identity is invalid"
    end

    manifest = specification.files.sort
    contents = package.contents.sort
    raise VerificationError, "internal checkpoint manifest and contents differ" unless manifest == contents
    missing = HitchFinalRelease::REQUIRED_FILES - manifest
    if missing.any?
      raise VerificationError, "internal checkpoint is missing contract files: #{missing.join(', ')}"
    end
    forbidden = manifest.select do |path|
      HitchFinalRelease::FORBIDDEN_PATHS.any? { |pattern| pattern.match?(path) }
    end
    if forbidden.any?
      raise VerificationError, "internal checkpoint contains forbidden paths: #{forbidden.join(', ')}"
    end

    { "files" => manifest.length, "public_contract" => "internal_checkpoint" }.freeze
  rescue Gem::Package::Error => error
    raise VerificationError, "internal checkpoint gem package is invalid: #{error.class}"
  end

  def checkpoint_from(evidence, kind:)
    if kind == "pre4_publication_decision"
      checkpoint = evidence.fetch("checkpoint")
      {
        "version" => checkpoint.fetch("version"),
        "status" => checkpoint.fetch("status"),
        "source_commit" => checkpoint.dig("source", "commit"),
        "source_tree" => checkpoint.dig("source", "tree"),
        "artifact" => checkpoint.dig("artifact", "name"),
        "sha256" => checkpoint.dig("artifact", "sha256")
      }
    else
      evidence.fetch("checkpoint")
    end
  rescue KeyError => error
    raise VerificationError, "#{kind} evidence is incomplete: #{error.key}"
  end
  private_class_method :checkpoint_from

  def normalize_checkpoint(checkpoint, version:)
    expected_keys = %w[version status source_commit source_tree artifact sha256]
    unless checkpoint.is_a?(Hash) && checkpoint.keys.sort == expected_keys.sort
      raise VerificationError, "#{version} checkpoint fields are invalid"
    end
    raise VerificationError, "#{version} checkpoint version drifted" unless checkpoint["version"] == version
    unless checkpoint["status"] == "accepted_internal_checkpoint"
      raise VerificationError, "#{version} checkpoint must be accepted and internal"
    end
    unless checkpoint["artifact"] == "hitch-rails-#{version}.gem"
      raise VerificationError, "#{version} checkpoint artifact name drifted"
    end
    unless COMMIT.match?(checkpoint["source_commit"].to_s) && COMMIT.match?(checkpoint["source_tree"].to_s)
      raise VerificationError, "#{version} checkpoint source identity is invalid"
    end
    unless SHA256.match?(checkpoint["sha256"].to_s)
      raise VerificationError, "#{version} checkpoint SHA-256 is invalid"
    end

    checkpoint.slice(*expected_keys).freeze
  end
  private_class_method :normalize_checkpoint
end
