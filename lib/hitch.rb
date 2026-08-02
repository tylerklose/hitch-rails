# frozen_string_literal: true

require "hitch/version"
require "hitch/rack_form_guard"
require "hitch/engine"
require "hitch/resource_uri"
require "hitch/pkce"
require "hitch/mcp/configuration"
require "hitch/configuration"
require "hitch/dynamic_registration_rate_limit"

# hitch-rails turns a Rails app into an authorization server implemented
# against the MCP 2026-07-28 authorization profile. OAuth 2.1 + PKCE (S256),
# Resource Indicators with audience binding (RFC 8707), discovery
# metadata (RFC 8414 + RFC 9728), token revocation (RFC 7009), and CORS
# for browser-based MCP clients. The 0.2 development line owns an authenticated
# host-mounted MCP endpoint, a public request-local Context, and a private Ruby
# SDK compatibility boundary. The explicit Registry descriptor surface is also
# active: it stores only reload-safe names and frozen data, then resolves host
# scope and deny-default availability for each request before static OAuth scope
# filtering. The accepted auth substrate remains the authority the endpoint
# validates tokens against. The final Tool call now freezes JSON arguments and
# runs deny-default argument policy before host execution; the closed Result
# channel remains a later M4 milestone.
#
# Spec reference: https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization
#
# Usage:
#   # config/initializers/hitch.rb
#   Hitch.configure do |config|
#     config.resource_uri = "https://example.com/mcp"  # for RFC 8707
#     config.allowed_hosts = []
#     config.allowed_origins = []
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
      Hitch::DynamicRegistrationRateLimit.reset_nonproduction_store!
    end
  end
end
