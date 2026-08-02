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
    redis = @specification.runtime_dependencies.find { |dependency| dependency.name == "redis" }

    assert_equal ">= 7.2, < 8.2", rails.requirement.to_s
    assert_equal ">= 2.13, < 3", json.requirement.to_s
    assert_equal ">= 2.4, < 3", json_schemer.requirement.to_s
    assert_equal ">= 1.1, < 2", mcp.requirement.to_s
    assert_equal ">= 5, < 7", redis.requirement.to_s
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
      docs/operator/redis.md
      docs/removing.md
      docs/upgrading/0.1.0.md
      docs/upgrading/0.2.0.md
      app/models/hitch/mcp/sdk_adapter.rb
      app/models/hitch/mcp/internal/sdk_adapter.rb
      app/models/hitch/mcp/internal/sdk_adapter/response_normalizer.rb
      app/models/hitch/mcp/internal/error_normalizer.rb
      app/models/hitch/mcp/internal/observation.rb
      app/models/hitch/mcp/internal/result_normalizer.rb
      app/models/hitch/mcp/internal/verified_request.rb
      app/models/hitch/mcp/context.rb
      app/models/hitch/mcp/forbidden.rb
      app/models/hitch/mcp/registry.rb
      app/models/hitch/mcp/result.rb
      app/models/hitch/mcp/memory_rate_store.rb
      app/models/hitch/mcp/rate_limit_key.rb
      app/models/hitch/mcp/redis_rate_store.rb
      app/models/hitch/mcp/request_rate_limiter.rb
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
    refute_includes @specification.files, "Rakefile"
  end

  test "package smoke names artifact installation rather than a checkout path dependency" do
    source = REPOSITORY_ROOT.join("bin/package-smoke").read

    assert_includes source, "local_gem_repository"
    assert_includes source, 'run!("gem", "generate_index"'
    assert_includes source, "package.contents.sort"
    assert_includes source, "package_input_snapshot"
    assert_includes source, "package inputs changed during smoke"
    assert_includes source, "verify_package_contract!"
    assert_includes source, "artifact_policy_for"
    assert_includes source, "bin/package-apps"
    assert_includes source, "bin/client-smokes"
    assert_includes source, 'gem "puma", "=#{PACKAGE_APP_SERVER_VERSION}"'
    assert_includes source, "automated_clients.host_environment"
    assert_match(/run!\([\s\S]*?"bundle", "exec", "rails", "db:drop"/, source)
    refute_includes source, 'system(database_environment, "bundle", "exec", "rails", "db:drop"'
    refute_includes source, 'gem "hitch-rails", path:'
  end

  test "sealed pre4 artifact remains internal after publication deferral" do
    version = @specification.version.to_s
    changelog = REPOSITORY_ROOT.join("CHANGELOG.md").read
    readme = REPOSITORY_ROOT.join("README.md").read
    security = REPOSITORY_ROOT.join("SECURITY.md").read
    contract_path = @artifact_policy.fetch("contract_path", "docs/public_api/#{version}.md")
    public_api = REPOSITORY_ROOT.join(contract_path).read
    development = @artifact_policy["development_version"] == version

    assert_equal "M5.4", @artifact_issue
    assert_equal "public_optional", @artifact_policy.fetch("distribution")
    assert_equal "0.2.0.pre.4", version
    refute development, "the accepted pre.4 build must use its sealed identity"
    assert_equal version, @artifact_policy.fetch("version")
    assert_match(/^## \[#{Regexp.escape(version)}\] - \d{4}-\d{2}-\d{2}$/, changelog)
    assert_includes changelog, "Internal verified checkpoint only"
    assert_includes changelog, "Public publication is deferred to final `0.2.0`"
    assert_includes readme, "There is no public RubyGems release yet"
    assert_includes readme, 'ref: ENV.fetch("HITCH_CHECKPOINT_SHA")'
    refute_includes readme, %(gem "hitch-rails", "~> #{version}")
    assert_includes security, "has no public RubyGems release"
    assert_includes public_api, "0.2.0"
    assert_includes public_api, "There is no public RubyGems release"
  end

  test "release check compares actual artifact contents with its embedded manifest" do
    source = REPOSITORY_ROOT.join("bin/release-check").read

    assert_includes source, "package.contents.sort"
    assert_includes source, "published_contents == published_files"
    assert_includes source, "FORBIDDEN_PACKAGE_PATHS"
    assert_includes source, "published gem contains forbidden paths"
    required_payload = source.match(/required = %W\[(?<files>.*?)\n  \]/m)[:files]
    refute_includes required_payload, "bin/release-check"
  end

  test "release check rejects internal and malformed versions before network access" do
    [ "0.1.0", "0.2.0.pre.3", "0.2.0.pre.4.dev", "not-a-release" ].each do |version|
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        REPOSITORY_ROOT.join("bin/release-check").to_s,
        version
      )

      assert_equal 64, status.exitstatus
      assert_includes stderr, "VERSION must be a public-eligible version at or after 0.2.0.pre.4"
    end
  end

  test "release check accepts the M5 prerelease syntax without touching release state" do
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      REPOSITORY_ROOT.join("bin/release-check").to_s,
      "--validate-version",
      "0.2.0.pre.4"
    )

    assert_predicate status, :success?, stderr
  end
end
