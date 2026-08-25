# frozen_string_literal: true

require "test_helper"
require "pathname"

# Gem-self-diagnosis, relocated here from the operator-facing doctor: whether
# the packaged file set is complete and leak-free is this repository's CI
# question, not something a host operator can act on.
class Hitch::PackageIntegrityTest < ActiveSupport::TestCase
  ROOT = Hitch::Engine.root
  SPECIFICATION = Gem::Specification.load(ROOT.join("hitch-rails.gemspec").to_s)
  REQUIRED_FILES = %w[
    app/controllers/concerns/hitch/mcp/endpoint.rb
    app/models/hitch/mcp/registry.rb
    app/models/hitch/mcp/rate_limit_key.rb
    app/models/hitch/mcp/tool.rb
    docs/adr/0006-device-authorization-grant.md
    docs/operator/doctor.md
    docs/operator/rate_limiting.md
    docs/removing.md
    lib/generators/hitch/install/install_generator.rb
    lib/generators/hitch/tool_generator.rb
    lib/hitch/doctor.rb
    lib/hitch/mcp/test_helper.rb
    lib/tasks/hitch.rake
  ].freeze
  # \A anchors the roots: a missing \A once matched a literal "A", flagging
  # innocent "Atest/"-style paths while real test/spec/tmp/log leaks passed.
  FORBIDDEN_PATH = %r{\A(?:test|spec|tmp|log)/}

  test "the gemspec packages every required runtime and operator file" do
    required = REQUIRED_FILES + Dir[ROOT.join("db/migrate/*.rb")].map do |path|
      "db/migrate/#{File.basename(path)}"
    end

    assert_empty required.uniq.sort - SPECIFICATION.files
  end

  # Derived rather than listed. The gemspec names the public API document
  # twice — spec.files and documentation_uri — and a hardcoded expectation
  # here would be a third place to update in lockstep, silently passing on the
  # release where someone forgot. This fails both ways: a new document that
  # was never packaged, and a superseded one still riding along.
  test "the gemspec packages exactly the public API document for this version" do
    expected = "docs/public_api/#{Hitch::VERSION.split('.').first(2).join('.')}.0.md"

    assert_path_exists ROOT.join(expected)
    assert_equal [ expected ], SPECIFICATION.files.grep(%r{\Adocs/public_api/})
    assert_includes SPECIFICATION.metadata.fetch("documentation_uri"), expected
  end

  test "the gemspec packages no test, spec, tmp, or log files" do
    assert_empty SPECIFICATION.files.grep(FORBIDDEN_PATH)
    assert_includes %w[lib/Atest/helper.rb test/leak_test.rb].grep(FORBIDDEN_PATH), "test/leak_test.rb"
    refute_includes %w[lib/Atest/helper.rb].grep(FORBIDDEN_PATH), "lib/Atest/helper.rb"
  end

  test "every packaged file exists on disk" do
    assert_empty SPECIFICATION.files.reject { |path| File.file?(ROOT.join(path)) }
  end

  test "relative links in packaged Markdown resolve inside the package" do
    broken = SPECIFICATION.files.grep(/\.md\z/).flat_map do |source|
      File.read(ROOT.join(source)).scan(/\]\(([^)]+)\)/).flatten.filter_map do |target|
        target = target.split(/\s+/, 2).first.to_s.delete_prefix("<").delete_suffix(">")
        next if target.empty? || target.start_with?("#") || target.match?(/\A[a-z][a-z0-9+.-]*:/i)

        path = target.split("#", 2).first
        resolved = Pathname.new(File.expand_path(path, ROOT.join(source).dirname))
          .relative_path_from(ROOT).to_s
        "#{source} -> #{resolved}" unless SPECIFICATION.files.include?(resolved)
      end
    end

    assert_empty broken
  end
end
