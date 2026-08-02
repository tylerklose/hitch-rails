# frozen_string_literal: true

require "test_helper"
require "open3"

class PackageContractTest < ActiveSupport::TestCase
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path
  GEMSPEC = REPOSITORY_ROOT.join("hitch-rails.gemspec")

  setup do
    @specification = Gem::Specification.load(GEMSPEC.to_s)
  end

  test "declares the exact supported runtime and framework window" do
    assert_equal ">= 3.3, < 4.1", @specification.required_ruby_version.to_s

    rails = @specification.runtime_dependencies.find { |dependency| dependency.name == "rails" }
    json = @specification.runtime_dependencies.find { |dependency| dependency.name == "json" }

    assert_equal ">= 7.2, < 8.2", rails.requirement.to_s
    assert_equal ">= 2.13, < 3", json.requirement.to_s
  end

  test "allowlist contains runtime, migrations, generator, and release contract only" do
    required = %w[
      app/controllers/concerns/hitch/oauth_form_admission.rb
      app/controllers/concerns/hitch/registration_admission.rb
      app/controllers/concerns/hitch/request_admission.rb
      config/routes.rb
      docs/public_api/0.1.0.md
      docs/removing.md
      docs/upgrading/0.1.0.md
      lib/generators/hitch/install/install_generator.rb
      lib/generators/hitch/install/templates/initializer.rb
    ]
    required.concat(Dir.chdir(REPOSITORY_ROOT) { Dir["db/migrate/*.rb"] })

    assert_empty required - @specification.files
    assert @specification.files.all? { |path| REPOSITORY_ROOT.join(path).file? },
      "the package manifest must contain files, never globbed directories"

    forbidden = @specification.files.grep(%r{\A(?:test|spec|tmp|log)/|\Adocs/(?:evidence|work_packets)/})
    assert_empty forbidden
    refute_includes @specification.files, "bin/ci"
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
    refute_includes source, 'gem "hitch-rails", path:'
  end

  test "internal checkpoint documentation does not claim public distribution" do
    version = @specification.version.to_s
    escaped_version = Regexp.escape(version)
    changelog = REPOSITORY_ROOT.join("CHANGELOG.md").read
    readme = REPOSITORY_ROOT.join("README.md").read
    security = REPOSITORY_ROOT.join("SECURITY.md").read
    public_api = REPOSITORY_ROOT.join("docs/public_api/#{version}.md").read

    assert_match(/^## \[#{escaped_version}\] - \d{4}-\d{2}-\d{2}$/, changelog)
    assert_includes changelog, "Internal verified checkpoint only"
    assert_includes readme, "There is no public RubyGems release yet"
    assert_includes readme, 'ref: ENV.fetch("HITCH_CHECKPOINT_SHA")'
    refute_includes readme, %(gem "hitch-rails", "~> #{version}")
    assert_includes security, "has no public RubyGems release"
    assert_includes public_api, version
    assert_includes public_api, "internal checkpoint artifact identity"
  end

  test "release check compares actual artifact contents with its embedded manifest" do
    source = REPOSITORY_ROOT.join("bin/release-check").read

    assert_includes source, "package.contents.sort"
    assert_includes source, "published_contents == published_files"
    assert_includes source, "FORBIDDEN_PACKAGE_PATHS"
    assert_includes source, "published gem contains forbidden paths"
  end

  test "release check rejects internal and malformed versions before network access" do
    [ "0.1.0", "0.2.0.pre.3", "not-a-release" ].each do |version|
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
