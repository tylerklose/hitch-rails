# frozen_string_literal: true

require "test_helper"
require "open3"

class PackageContractTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  GEMSPEC = REPOSITORY_ROOT.join("hitch-rails.gemspec")

  setup do
    @specification = Gem::Specification.load(GEMSPEC.to_s)
    @work_packets = YAML.safe_load_file(REPOSITORY_ROOT.join("docs/work_packets/index.yml"))
    @artifact_issue, @artifact_policy = @work_packets.fetch("nodes").filter_map do |issue, metadata|
      artifact = metadata["artifact"]
      next unless artifact
      next unless [ artifact["version"], artifact["development_version"] ].include?(@specification.version.to_s)

      [ issue, artifact ]
    end.fetch(0)
  end

  test "declares the exact supported runtime and framework window" do
    assert_equal ">= 3.3, < 4.1", @specification.required_ruby_version.to_s

    rails = @specification.runtime_dependencies.find { |dependency| dependency.name == "rails" }
    json = @specification.runtime_dependencies.find { |dependency| dependency.name == "json" }
    json_schemer = @specification.runtime_dependencies.find { |dependency| dependency.name == "json_schemer" }
    mcp = @specification.runtime_dependencies.find { |dependency| dependency.name == "mcp" }

    assert_equal ">= 7.2, < 8.2", rails.requirement.to_s
    assert_equal ">= 2.13, < 3", json.requirement.to_s
    assert_equal ">= 2.4, < 3", json_schemer.requirement.to_s
    assert_equal ">= 1.1, < 2", mcp.requirement.to_s

    # Request admission counts through the host's own ActiveSupport::Cache
    # store, so Hitch adds no service to a deployment that has none.
    assert_equal %w[json json_schemer mcp rails],
      @specification.runtime_dependencies.map(&:name).sort
  end

  test "allowlist contains runtime, migrations, generator, and release contract only" do
    required = %w[
      app/controllers/concerns/hitch/oauth_form_admission.rb
      app/controllers/concerns/hitch/registration_admission.rb
      app/controllers/concerns/hitch/request_admission.rb
      app/controllers/concerns/hitch/mcp/endpoint.rb
      config/routes.rb
      docs/public_api/0.1.0.md
      docs/public_api/0.2.0.md
      docs/operator/doctor.md
      docs/operator/rate_limiting.md
      docs/removing.md
      docs/upgrading/0.1.0.md
      docs/upgrading/0.2.0.md
      app/models/hitch/mcp/sdk_adapter.rb
      app/models/hitch/mcp/internal/sdk_adapter.rb
      app/models/hitch/mcp/internal/sdk_adapter/response_normalizer.rb
      app/models/hitch/mcp/internal/endpoint_error_reporter.rb
      app/models/hitch/mcp/internal/error_normalizer.rb
      app/models/hitch/mcp/internal/observation.rb
      app/models/hitch/mcp/internal/result_normalizer.rb
      app/models/hitch/mcp/internal/verified_request.rb
      app/models/hitch/mcp/context.rb
      app/models/hitch/mcp/forbidden.rb
      app/models/hitch/mcp/registry.rb
      app/models/hitch/mcp/result.rb
      app/models/hitch/mcp/rate_limit_key.rb
      app/models/hitch/mcp/tool.rb
      app/models/hitch/mcp/verified_request.rb
      lib/generators/hitch/install/install_generator.rb
      lib/generators/hitch/install/templates/initializer.rb
      lib/generators/hitch/mcp/install_generator.rb
      lib/generators/hitch/mcp/templates/controller.rb.tt
      lib/generators/hitch/mcp/templates/initializer.rb.tt
      lib/generators/hitch/mcp/templates/registry.rb.tt
      lib/generators/hitch/tool_generator.rb
      lib/generators/hitch/tool/templates/tool.rb.tt
      lib/generators/hitch/tool/templates/tool_test.rb.tt
      lib/hitch/mcp/configuration.rb
      lib/hitch/mcp/test_helper.rb
      lib/hitch/doctor.rb
      lib/tasks/hitch.rake
    ]
    required.concat(Dir.chdir(REPOSITORY_ROOT) { Dir["db/migrate/*.rb"] })

    assert_empty required - @specification.files
    assert @specification.files.all? { |path| REPOSITORY_ROOT.join(path).file? },
      "the package manifest must contain files, never globbed directories"

    forbidden = @specification.files.grep(%r{\A(?:test|spec|tmp|log)/|\Adocs/(?:evidence|work_packets)/})
    assert_empty forbidden
    refute_includes @specification.files, "bin/ci"
    refute_includes @specification.files, "bin/client-smokes"
    refute_includes @specification.files, "bin/package-apps"
    refute_includes @specification.files, "bin/package-smoke"
    refute_includes @specification.files, "bin/release-check"
    refute_includes @specification.files, "bin/prepare-release-artifact"
    refute_includes @specification.files, "bin/final-local-gates"
    refute_includes @specification.files, "bin/validate-release-evidence-draft"
    refute_includes @specification.files, "tooling/release_artifact.rb"
    refute_includes @specification.files, "tooling/package_distribution.rb"
    refute_includes @specification.files, "tooling/final_release.rb"
    refute_includes @specification.files, "tooling/exclusive_report.rb"
    refute_includes @specification.files, "tooling/final_local_gates.rb"
    refute_includes @specification.files, "tooling/artifact_staging.rb"
    refute_includes @specification.files, "tooling/checkpoint_release.rb"
    refute_includes @specification.files, "tooling/milestone_local_gate.rb"
    refute_includes @specification.files, "tooling/downloaded_release.rb"
    refute_includes @specification.files, "tooling/evidence_draft.rb"
    refute_includes @specification.files, "Rakefile"
  end

  test "package smoke names artifact installation rather than a checkout path dependency" do
    source = REPOSITORY_ROOT.join("bin/package-smoke").read
    artifact_source = REPOSITORY_ROOT.join("tooling/release_artifact.rb").read

    assert_includes source, "local_gem_repository"
    assert_includes source, 'run!("gem", "generate_index"'
    assert_includes source, "package.contents.sort"
    assert_includes source, "package_input_snapshot"
    assert_includes source, "package inputs changed during smoke"
    assert_includes source, "verify_package_contract!"
    assert_includes source, "HitchPackageDistribution.resolve("
    assert_includes source, '"distribution" => effective_distribution'
    assert_includes source, '"distribution_policy" => artifact_policy.fetch("distribution")'
    assert_includes source, "artifact_policy_for"
    assert_includes source, "accepted_checkpoint_for"
    assert_includes source, "accepted_commit_rebuild"
    assert_includes source, "SEALED_CHECKOUT_DRIFT_ALLOWLIST = %w[ROADMAP.md]"
    assert_includes source, "HitchReleaseArtifact.rebuild!"
    assert_includes source, "source_tree"
    assert_includes artifact_source, 'capture!("git", "merge-base", "--is-ancestor", commit, "HEAD"'
    assert_includes artifact_source, 'capture!("git", "archive", "--format=tar"'
    assert_includes artifact_source, "rebuilt gem SHA-256 differs"
    assert_includes source, "bin/package-apps"
    assert_includes source, "bin/client-smokes"
    assert_includes source, 'gem "puma", "=#{PACKAGE_APP_SERVER_VERSION}"'
    assert_includes source, "automated_clients.host_environment"
    assert_match(/run!\([\s\S]*?"bundle", "exec", "rails", "db:drop"/, source)
    refute_includes source, 'system(database_environment, "bundle", "exec", "rails", "db:drop"'
    refute_includes source, 'gem "hitch-rails", path:'
  end

  test "post-pre4 development remains internal while preserving the sealed checkpoint" do
    version = @specification.version.to_s
    changelog = REPOSITORY_ROOT.join("CHANGELOG.md").read
    readme = REPOSITORY_ROOT.join("README.md").read
    security = REPOSITORY_ROOT.join("SECURITY.md").read
    contract_path = @artifact_policy.fetch("contract_path", "docs/public_api/#{version}.md")
    public_api = REPOSITORY_ROOT.join(contract_path).read
    development = @artifact_policy["development_version"] == version

    assert_equal "M6", @artifact_issue
    assert_equal "public_if_pre4_published", @artifact_policy.fetch("distribution")
    assert_equal "0.2.0.rc1.dev", version
    assert development, "post-checkpoint work must use the M6 development identity"
    assert_equal "0.2.0.rc1", @artifact_policy.fetch("version")
    assert_match(/^## \[Unreleased\]$/, changelog)
    assert_includes changelog, "Internal development build only"
    assert_includes changelog, "sealed internal `0.2.0.pre.4` checkpoint"
    assert_includes changelog, "Public publication is deferred to final `0.2.0`"
    assert_includes readme, "There is no public RubyGems release yet"
    assert_includes readme, 'ref: ENV.fetch("HITCH_CHECKPOINT_SHA")'
    refute_includes readme, %(gem "hitch-rails", "~> #{version}")
    assert_includes security, "has no public RubyGems release"
    assert_includes public_api, "0.2.0"
    assert_includes public_api, "There is no public RubyGems release"
  end

  test "each unfinished RC milestone has a distinct mutable development identity" do
    m6 = @work_packets.dig("nodes", "M6", "artifact")
    m7 = @work_packets.dig("nodes", "M7", "artifact")

    assert_equal "0.2.0.rc1.dev", m6.fetch("development_version")
    assert_equal "0.2.0.rc2.dev", m7.fetch("development_version")
    refute_equal m7.fetch("version"), m7.fetch("development_version")
  end

  test "durable release outputs are published only after source postconditions" do
    package_source = REPOSITORY_ROOT.join("bin/package-smoke").read
    release_source = REPOSITORY_ROOT.join("bin/release-check").read
    preparation_source = REPOSITORY_ROOT.join("bin/prepare-release-artifact").read

    assert_operator package_source.index("package smoke changed the worktree"), :<,
      package_source.index("HitchExclusiveReport.write!")
    assert_operator release_source.rindex("verify_checkout_unchanged!"), :<,
      release_source.index("HitchExclusiveReport.write!")
    assert_includes preparation_source, "before_publish: source_postcondition"
  end

  test "release check compares actual artifact contents with its embedded manifest" do
    source = REPOSITORY_ROOT.join("bin/release-check").read

    assert_includes source, "package.contents.sort"
    assert_includes source, "published_contents == published_files"
    assert_includes source, "FORBIDDEN_PACKAGE_PATHS"
    assert_includes source, "published gem contains forbidden paths"
    assert_includes source, "publication_authority_sha256"
    assert_includes source, "tag_target_commit"
    assert_includes source, "tag_target_tree"
    assert_includes source, "release check requires a clean worktree"
    assert_operator source.index("release check requires a clean worktree"), :<,
      source.index("bin/verify-release-policy")
    assert_operator source.index("bin/verify-release-policy"), :<, source.index('tag = "v#{version}"')
    assert_operator source.index("bin/verify-release-evidence"), :<, source.index('tag = "v#{version}"')
    assert_operator source.index("bin/verify-release-matrix"), :<, source.index('tag = "v#{version}"')
    required_payload = source.match(/required = %W\[(?<files>.*?)\n  \]/m)[:files]
    refute_includes required_payload, "bin/release-check"
  end

  test "candidate preparation is source-bound clean and downstream of M7" do
    source = REPOSITORY_ROOT.join("bin/prepare-release-artifact").read

    assert_includes source, 'ARGV.delete("--candidate")'
    assert_includes source, 'ARGV.delete("--checkpoint")'
    assert_includes source, '[ "--through", "M7" ]'
    assert_includes source, "preparing a release artifact requires a clean worktree"
    assert_includes source, "HitchReleaseArtifact.rebuild!"
    assert_includes source, "HitchFinalRelease.validate_package!"
    assert_includes source, "stager.stage!"
    assert_includes source, "HitchCheckpointRelease.candidate!"
    assert_includes source, "before_publish: source_postcondition"
  end

  test "release check rejects internal and malformed versions before network access" do
    [ "0.1.0", "0.2.0.pre.3", "0.2.0.pre.4.dev", "not-a-release" ].each do |version|
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        REPOSITORY_ROOT.join("bin/release-check").to_s,
        version
      )

      assert_equal 64, status.exitstatus
      assert_includes stderr, "VERSION must be one of 0.2.0.pre.4, 0.2.0.rc1, 0.2.0.rc2, 0.2.0"
    end
  end

  test "release check rejects public pre4 after the recorded deferral before touching release state" do
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      REPOSITORY_ROOT.join("bin/release-check").to_s,
      "--validate-version",
      "0.2.0.pre.4"
    )

    assert_not status.success?
    assert_includes stderr, release_check_precondition("deferred public RubyGems publication until 0.2.0")
    refute_includes stderr, "must be an annotated tag"
  end

  test "release check requires final adoption evidence before tag or network access" do
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      REPOSITORY_ROOT.join("bin/release-check").to_s,
      "--validate-version",
      "0.2.0"
    )

    assert_not status.success?
    assert_includes stderr, release_check_precondition("0.2.0 public preflight is missing accepted evidence")
    assert_includes stderr, "adoption/copied-lineage.json" if repository_clean?
    refute_includes stderr, "must be an annotated tag"
  end

  test "live completion fails on missing committed evidence before tag or network access" do
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      REPOSITORY_ROOT.join("bin/release-check").to_s,
      "--complete",
      "0.2.0"
    )

    assert_not status.success?
    assert_includes stderr, release_check_precondition("post-publication completion is missing accepted evidence")
    assert_includes stderr, "release/downloaded-gem.json" if repository_clean?
    refute_includes stderr, "must be an annotated tag"
  end

  private

  def repository_clean?
    status, result = Open3.capture2e(
      "git", "status", "--porcelain=v1", "-z", "--untracked-files=all",
      chdir: REPOSITORY_ROOT
    )
    result.success? && status.empty?
  end

  def release_check_precondition(clean_message)
    repository_clean? ? clean_message : "release check requires a clean worktree"
  end
end
