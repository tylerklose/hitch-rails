require_relative "lib/hitch/version"

Gem::Specification.new do |spec|
  spec.name        = "hitch-rails"
  spec.version     = Hitch::VERSION
  spec.authors     = [ "Tyler Klose" ]
  spec.email       = [ "tylerklose@gmail.com" ]
  spec.homepage    = "https://github.com/tylerklose/hitch-rails"
  spec.summary     = "Opinionated authenticated MCP framework for Rails"
  spec.description = <<~DESC
    Hitch is an opinionated authenticated MCP framework for Rails apps,
    implemented against the MCP 2026-07-28 authorization profile. It bundles
    OAuth 2.1 + PKCE (S256), optional Dynamic Client
    Registration (RFC 7591), Resource Indicators with audience binding (RFC 8707),
    discovery metadata (RFC 8414 + RFC 9728), token revocation (RFC 7009),
    and CORS for browser-based MCP clients. Hitch directly integrates the Ruby
    MCP SDK behind a private compatibility boundary and
    provides a strict authenticated endpoint, a public request-local Context,
    and an atomically validated host Registry with request-local scope
    resolution, deny-default availability, static OAuth scope filtering, and
    deterministic private listings. The final Tool call freezes string-keyed
    JSON arguments and runs deny-default argument policy before host execution.
    Its closed Result channel validates and caps output while preserving only
    explicit safe error messages. Host-cache-backed request admission and
    structural-only request/invocation notifications complete the runtime
    boundary. A collision-safe Rails generator installs the host-owned MCP
    controller, empty explicit Registry, deny-default settings, and ordered
    route with checksum-guarded rollback. A separate explicit generator creates
    deny-default tool/test pairs without editing the Registry, and a public
    test helper constructs the final authenticated Rails integration requests.
    A read-only doctor reports stable versioned configuration, discovery,
    routing, migration, Registry, ingress, admission-store, package, and
    legacy-endpoint findings without exposing credentials or repairing host
    state.
    A deprecated ServerEndpoint
    compatibility concern remains available through the 0.2 line for bearer
    validation and basic MCP Streamable HTTP response shaping. Principal lookup is
    host-configurable, browser origins are exact and default-deny, and both
    SQLite and PostgreSQL are supported.
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
      ROADMAP.md
      SECURITY.md
      config/routes.rb
      docs/public_api/0.1.0.md
      docs/public_api/0.2.0.md
      docs/operator/doctor.md
      docs/operator/rate_limiting.md
      docs/removing.md
      docs/upgrading/0.1.0.md
      docs/upgrading/0.2.0.md
      lib/generators/hitch/mcp/templates/controller.rb.tt
      lib/generators/hitch/mcp/templates/initializer.rb.tt
      lib/generators/hitch/mcp/templates/registry.rb.tt
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
  spec.add_dependency "mcp", ">= 1.1", "< 2"
  spec.add_dependency "rails", ">= 7.2", "< 8.2"
end
