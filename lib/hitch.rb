# frozen_string_literal: true

require "hitch/version"
require "hitch/engine"
require "hitch/configuration"

# hitch-rails turns a Rails app into a spec-conformant MCP authorization
# server. OAuth 2.1 + PKCE (S256), Dynamic Client Registration (RFC 7591),
# Resource Indicators with audience binding (RFC 8707), discovery
# metadata (RFC 8414 + RFC 9728), token revocation (RFC 7009), and CORS
# for browser-based MCP clients. The host owns the MCP transport
# endpoint (/mcp); this gem provides the auth substrate the host queries
# to validate tokens.
#
# Spec reference: https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization
#
# The principal model is host-app configurable (defaults to "User") so
# apps with different identity schemas can adopt the gem without
# surgery.
#
# Usage:
#   # config/initializers/hitch.rb
#   Hitch.configure do |config|
#     config.principal_model = "User"   # or "Account", "MCPClient", etc.
#     config.resource_uri = "https://example.com/mcp"  # for RFC 8707
#   end
module Hitch
  class << self
    # @yield [Configuration] the gem's configuration
    # @return [Configuration] the (potentially modified) configuration
    def configure
      yield(configuration) if block_given?
      configuration
    end

    # @return [Configuration]
    def configuration
      @configuration ||= Configuration.new
    end

    # Reset configuration (useful in tests).
    def reset_configuration!
      @configuration = nil
    end
  end
end
