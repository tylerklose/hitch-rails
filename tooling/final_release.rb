# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "rubygems/package"
require "tmpdir"
require_relative "artifact_staging"
require_relative "release_artifact"

module HitchFinalRelease
  RELEASE = "0.2.0"
  GEM_NAME = "hitch-rails"
  ROADMAP_RELEASE_STATUS = "> Status: completed for the public `0.2.0` release."
  METADATA_CONTRACT = /opinionated authenticated MCP framework for Rails/i
  INDEX_PATH = "docs/evidence/0.2.0/index.json"
  CANDIDATE_KEYS = %w[version artifact sha256 source_commit source_tree tag].freeze
  REQUIRED_FILES = %w[
    CHANGELOG.md
    README.md
    ROADMAP.md
    SECURITY.md
    docs/public_api/0.2.0.md
    docs/removing.md
    docs/upgrading/0.2.0.md
    lib/hitch/version.rb
  ].freeze
  FORBIDDEN_PATHS = [
    %r{\A(?:test|spec|tmp|log)/},
    %r{\Adocs/(?:evidence|work_packets)/},
    %r{\A\.git},
    %r{(?:\A|/)\.env(?:\.|\z)},
    %r{(?:\A|/)master\.key\z},
    %r{(?:\A|/)credentials\.ya?ml\.enc\z},
    %r{\.(?:pem|key)\z}
  ].freeze
  FORBIDDEN_PUBLIC_STATUS = [
    /there is no public rubygems release/i,
    /no `?hitch-rails`? version is available from rubygems/i,
    /no 0\.2 artifact has been published/i,
    /not a public release/i,
    /first planned public release/i,
    /public(?: rubygems)? publication (?:is|remains) deferred/i,
    /internal development build/i,
    /\b0\.2 development (?:line|surface)\b/i,
    /internal[- ]checkpoint 0\.2\.0/i,
    /internal `?0\.2\.0[^`\s]*`? checkpoint/i,
    /(?:current|latest|accepted|sealed) internal (?:checkpoint|prerelease)/i,
    /adopting the internal hitch 0\.2/i,
    /unreleased `?0\.2\.0(?:\.rc\d+(?:\.dev)?)?/i
  ].freeze

  class VerificationError < StandardError; end

  module_function

  def candidate!(root:, authority:)
    kind = authority ? "publication_authority" : "final_check"
    evidence, record = indexed_evidence!(root:, kind:)
    candidate = if authority
      evidence.fetch("candidate")
    else
      evidence.fetch("release").slice(*CANDIDATE_KEYS)
    end
    unless candidate.is_a?(Hash) && candidate.keys.sort == CANDIDATE_KEYS.sort &&
        candidate["version"] == RELEASE && candidate["artifact"] == "#{GEM_NAME}-#{RELEASE}.gem" &&
        candidate["tag"] == "v#{RELEASE}"
      raise VerificationError, "#{kind} candidate identity is invalid"
    end

    {
      "candidate" => candidate,
      "evidence_path" => record.fetch("path"),
      "evidence_sha256" => record.fetch("sha256")
    }.freeze
  rescue KeyError => error
    raise VerificationError, "#{kind} evidence is incomplete: #{error.key}"
  end

  def accepted_evidence!(root:, kind:)
    evidence, record = indexed_evidence!(root:, kind:)
    { "evidence" => evidence, "record" => record }.freeze
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

  def validate_package!(artifact:, version: RELEASE)
    package = Gem::Package.new(artifact)
    specification = package.spec
    raise VerificationError, "release gem name is invalid" unless specification.name == GEM_NAME
    raise VerificationError, "release gem version is invalid" unless specification.version.to_s == version
    validate_gem_metadata!(specification)

    manifest = specification.files.sort
    contents = package.contents.sort
    raise VerificationError, "release gem manifest and contents differ" unless manifest == contents
    missing = REQUIRED_FILES - manifest
    raise VerificationError, "release gem is missing contract files: #{missing.join(', ')}" if missing.any?
    forbidden = manifest.select { |path| FORBIDDEN_PATHS.any? { |pattern| pattern.match?(path) } }
    raise VerificationError, "release gem contains forbidden paths: #{forbidden.join(', ')}" if forbidden.any?

    Dir.mktmpdir("hitch-final-release-") do |directory|
      package.extract_files(directory)
      validate_public_documents!(directory, version)
    end
    { "files" => manifest.length, "public_contract" => "match" }.freeze
  rescue Gem::Package::Error => error
    raise VerificationError, "release gem package is invalid: #{error.class}"
  end

  def indexed_evidence!(root:, kind:)
    root = File.realpath(root)
    index = parse_json!(File.join(root, INDEX_PATH), INDEX_PATH)
    record = index.fetch("records").find { |candidate| candidate["kind"] == kind }
    raise VerificationError, "release evidence index has no #{kind}" unless record
    raise VerificationError, "#{kind} is not accepted" unless record["status"] == "accepted"

    relative_path = record.fetch("path")
    path = Pathname.new(relative_path)
    unless !path.absolute? && path.cleanpath.to_s == relative_path &&
        relative_path.start_with?("docs/evidence/0.2.0/")
      raise VerificationError, "#{kind} evidence path is unsafe"
    end
    absolute_path = File.join(root, relative_path)
    raise VerificationError, "#{kind} evidence must be a regular file" unless File.file?(absolute_path) && !File.symlink?(absolute_path)
    digest = Digest::SHA256.file(absolute_path).hexdigest
    raise VerificationError, "#{kind} evidence SHA differs from the index" unless digest == record["sha256"]

    [ parse_json!(absolute_path, relative_path), record ]
  rescue KeyError => error
    raise VerificationError, "release evidence index is incomplete: #{error.key}"
  end
  private_class_method :indexed_evidence!

  def parse_json!(path, label)
    JSON.parse(File.binread(path), allow_duplicate_key: false)
  rescue Errno::ENOENT, JSON::ParserError => error
    raise VerificationError, "#{label} is invalid: #{error.class}"
  end
  private_class_method :parse_json!

  def validate_public_documents!(root, version)
    version_source = read_utf8!(File.join(root, "lib/hitch/version.rb"))
    unless version_source.match?(/VERSION\s*=\s*["']#{Regexp.escape(version)}["']/)
      raise VerificationError, "release version source does not identify #{version}"
    end

    changelog = read_utf8!(File.join(root, "CHANGELOG.md"))
    unless changelog.match?(/^## \[#{Regexp.escape(version)}\] - \d{4}-\d{2}-\d{2}$/)
      raise VerificationError, "release changelog has no dated #{version} heading"
    end
    unless empty_unreleased_changelog?(changelog)
      raise VerificationError, "release changelog still has unreleased content"
    end
    roadmap = read_utf8!(File.join(root, "ROADMAP.md"))
    unless roadmap.match?(/\A# .+\n\n#{Regexp.escape(ROADMAP_RELEASE_STATUS)}(?:\n|\z)/)
      raise VerificationError, "release roadmap has not crossed the completed public boundary"
    end
    readme = read_utf8!(File.join(root, "README.md"))
    unless readme.include?(%(gem "hitch-rails", "~> #{version}")) &&
        readme.include?("**Public release #{version}.**") &&
        readme.match?(/four-lane release matrix/i) &&
        public_status_final?(readme)
      raise VerificationError, "release README has not crossed the public installation boundary"
    end
    security = read_utf8!(File.join(root, "SECURITY.md"))
    unless security.match?(/^\| `0\.2\.x`\s+\| ✅\s+\|$/) &&
        public_status_final?(security)
      raise VerificationError, "release security policy has not crossed the public support boundary"
    end
    public_api = read_utf8!(File.join(root, "docs/public_api/0.2.0.md"))
    unless public_api.match?(/^# .*0\.2\.0 public API$/i) &&
        public_api.include?("Status: public #{version} release.") &&
        public_status_final?(public_api)
      raise VerificationError, "release public API document still describes an internal checkpoint"
    end
    upgrading = read_utf8!(File.join(root, "docs/upgrading/0.2.0.md"))
    unless upgrading.match?(/^# Upgrading to Hitch #{Regexp.escape(version)}$/) &&
        upgrading.include?("This guide applies to the public hitch-rails #{version} release.") &&
        public_status_final?(upgrading)
      raise VerificationError, "release upgrading guide still describes an internal checkpoint"
    end
  end
  private_class_method :validate_public_documents!

  def validate_gem_metadata!(specification)
    summary = specification.summary.to_s
    description = specification.description.to_s
    unless METADATA_CONTRACT.match?(summary) && METADATA_CONTRACT.match?(description) &&
        description.match?(/\bRegistry\b/) && public_status_final?(description)
      raise VerificationError, "release gem metadata still describes a development-only product"
    end
  end
  private_class_method :validate_gem_metadata!

  def empty_unreleased_changelog?(contents)
    match = contents.match(/^## \[Unreleased\]\s*$\n(?<body>.*?)(?=^## \[)/m)
    match && match[:body].strip.empty?
  end
  private_class_method :empty_unreleased_changelog?

  def public_status_final?(contents)
    FORBIDDEN_PUBLIC_STATUS.none? { |pattern| pattern.match?(contents) }
  end
  private_class_method :public_status_final?

  def read_utf8!(path)
    value = File.binread(path).force_encoding(Encoding::UTF_8)
    raise VerificationError, "release contract document is not valid UTF-8" unless value.valid_encoding?

    value
  end
  private_class_method :read_utf8!
end
