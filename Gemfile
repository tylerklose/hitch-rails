source "https://rubygems.org"

# Specify your gem's dependencies in hitch-rails.gemspec.
gemspec

gem "puma"

gem "pg"

# Test-only: the official MCP SDK. Hitch does NOT depend on `mcp` at
# runtime (the host owns the /mcp transport and its `mcp` dependency) —
# but the gem's own suite uses it to drive a REAL MCP server through
# Hitch::ServerEndpoint, so the 202/200 Streamable HTTP contract is
# verified against actual SDK output, not a simulation. `require: false`
# so it isn't auto-loaded on app boot (Bundler.require) — only the real
# MCP test requires it explicitly.
gem "mcp", "~> 0.18", group: :test, require: false

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false

# Start debugger with binding.b [https://github.com/ruby/debug]
# gem "debug", ">= 1.0.0"
