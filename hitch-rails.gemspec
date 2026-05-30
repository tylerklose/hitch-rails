require_relative "lib/hitch/version"

Gem::Specification.new do |spec|
  spec.name        = "hitch-rails"
  spec.version     = Hitch::VERSION
  spec.authors     = [ "Tyler Klose" ]
  spec.email       = [ "tylerklose@gmail.com" ]
  spec.homepage    = "https://github.com/tylerklose/hitch-rails"
  spec.summary     = "OAuth 2.1 + PKCE authorization server for Rails-hosted MCP servers"
  spec.description = <<~DESC
    Hitch turns a Rails app into a spec-conformant MCP authorization
    server. Bundles OAuth 2.1 + PKCE (S256), Dynamic Client Registration
    (RFC 7591), Resource Indicators with audience binding (RFC 8707),
    discovery metadata (RFC 8414 + RFC 9728), token revocation (RFC 7009),
    and CORS for browser-based MCP clients. The host owns the /mcp
    transport and its tool dispatch; Hitch provides the auth substrate it
    validates tokens against, plus a ServerEndpoint concern for
    spec-correct MCP Streamable HTTP response shaping. The principal model
    is host-configurable (defaults to User) so apps with different identity
    schemas can adopt without surgery. Postgres required (the clients
    table uses an array column).
  DESC
  spec.license = "MIT"

  # spec.homepage above is the canonical repo URL; rubygems pulls
  # homepage_uri from it automatically. source_code_uri intentionally
  # omitted to avoid the duplicate-URI warning when both pointed at the
  # same place.
  spec.metadata["changelog_uri"] = "https://github.com/tylerklose/hitch-rails/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/tylerklose/hitch-rails/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.required_ruby_version = ">= 3.3.0"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  end

  # This gem provides the OAuth/auth substrate only — it does not use
  # the `mcp` SDK itself (the host owns the /mcp transport endpoint and
  # depends on `mcp` directly). Adding it here would force a heavy,
  # version-coupled dependency on every adopter for nothing.
  spec.add_dependency "rails", ">= 7.1", "< 10"
end
