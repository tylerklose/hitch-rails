require_relative "lib/hitch/version"

Gem::Specification.new do |spec|
  spec.name        = "hitch-rails"
  spec.version     = Hitch::VERSION
  spec.authors     = [ "Tyler Klose" ]
  spec.homepage    = "https://github.com/tylerklose/hitch-rails"
  spec.summary     = "Let AI agents call your Rails app's tools: an OAuth 2.1 authorization server plus an authenticated MCP endpoint, built on the sign-in you already have"
  spec.description = <<~DESC
    Hitch lets MCP clients -- Claude, ChatGPT, Cursor -- call your Rails
    app's tools as a specific signed-in user, with access you can revoke.

    You do not stand up a separate auth server, add Redis, or adopt a new
    sign-in system. Hitch uses the authentication your app already has
    (current_user or Current.user) and your configured cache store.

    Underneath it is a full OAuth 2.1 authorization server implementing the
    MCP 2026-07-28 authorization profile: PKCE (S256), audience-bound tokens
    (RFC 8707), discovery metadata (RFC 8414 + RFC 9728), revocation
    (RFC 7009), Client ID Metadata Documents, and optional Dynamic Client
    Registration (RFC 7591). It adds an authenticated /mcp endpoint backed by
    the official Ruby MCP SDK and a deny-default tool registry with schema
    validation and size caps. SQLite and PostgreSQL supported.
  DESC
  spec.license = "MIT"

  # spec.homepage above is the canonical repo URL; rubygems pulls
  # homepage_uri from it automatically. source_code_uri intentionally
  # omitted to avoid the duplicate-URI warning when both pointed at the
  # same place.
  spec.metadata["changelog_uri"] = "https://github.com/tylerklose/hitch-rails/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/tylerklose/hitch-rails/issues"
  # A mis-set RUBYGEMS_HOST would otherwise publish this somewhere else.
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["documentation_uri"] = "https://github.com/tylerklose/hitch-rails/blob/v0.4.0/docs/public_api/0.4.0.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.required_ruby_version = Gem::Requirement.new(">= 3.3", "< 4.1")

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    files = %w[
      CHANGELOG.md
      MIT-LICENSE
      README.md
      SECURITY.md
      config/routes.rb
      docs/adr/0006-device-authorization-grant.md
      docs/public_api/0.4.0.md
      docs/operator/doctor.md
      docs/operator/rate_limiting.md
      docs/removing.md
      docs/upgrading/0.2-to-0.3.md
      docs/upgrading/0.3-to-0.4.md
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
    # Intersected with what git tracks: the globs are convenient, but on
    # their own an untracked scratch file in app/ or lib/ would be packaged
    # and published, and nothing before `gem push` would catch it.
    tracked = `git ls-files -z`.split("\x0")
    files.select { |path| File.file?(path) && tracked.include?(path) }.sort
  end

  spec.add_dependency "json", ">= 2.13", "< 3"
  spec.add_dependency "json_schemer", ">= 2.4", "< 3"
  spec.add_dependency "mcp", ">= 1.4", "< 2"
  spec.add_dependency "rails", ">= 8.0", "< 9"
end
