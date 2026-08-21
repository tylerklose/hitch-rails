require_relative "lib/hitch/version"

Gem::Specification.new do |spec|
  spec.name        = "hitch-rails"
  spec.version     = Hitch::VERSION
  spec.authors     = [ "Tyler Klose" ]
  spec.homepage    = "https://github.com/tylerklose/hitch-rails"
  spec.summary     = "Opinionated authenticated MCP framework for Rails"
  spec.description = <<~DESC
    Hitch turns a Rails app into an MCP authorization server: OAuth 2.1 +
    PKCE, audience-bound tokens, discovery metadata, revocation, and
    default-deny CORS, built on the sign-in the app already has. It adds an
    authenticated /mcp endpoint backed by the official Ruby MCP SDK and an
    explicit deny-default tool registry with schema-validated, size-capped
    results. Request admission counts through the app's own cache store — no
    Redis, no separate auth server — with SQLite and PostgreSQL supported.
  DESC
  spec.license = "MIT"

  # spec.homepage above is the canonical repo URL; rubygems pulls
  # homepage_uri from it automatically. source_code_uri intentionally
  # omitted to avoid the duplicate-URI warning when both pointed at the
  # same place.
  spec.metadata["changelog_uri"] = "https://github.com/tylerklose/hitch-rails/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/tylerklose/hitch-rails/issues"
  spec.metadata["documentation_uri"] = "https://github.com/tylerklose/hitch-rails/blob/main/docs/public_api/0.2.0.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.required_ruby_version = Gem::Requirement.new(">= 3.3", "< 4.1")

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    files = %w[
      CHANGELOG.md
      MIT-LICENSE
      README.md
      SECURITY.md
      config/routes.rb
      docs/public_api/0.2.0.md
      docs/operator/doctor.md
      docs/operator/rate_limiting.md
      docs/removing.md
      lib/generators/hitch/install/templates/controller.rb.tt
      lib/generators/hitch/tool/templates/tool.rb.tt
      lib/generators/hitch/tool/templates/tool_test.rb.tt
    ]
    files.concat(
      Dir[
        "app/controllers/**/*.rb",
        "app/models/**/*.rb",
        "app/views/**/*.erb",
        "db/migrate/*.rb",
        "lib/**/*.rake",
        "lib/**/*.rb"
      ]
    )
    files.select { |path| File.file?(path) }.sort
  end

  spec.add_dependency "json", ">= 2.13", "< 3"
  spec.add_dependency "json_schemer", ">= 2.4", "< 3"
  spec.add_dependency "mcp", ">= 1.2", "< 2"
  spec.add_dependency "rails", ">= 8.0", "< 9"
end
