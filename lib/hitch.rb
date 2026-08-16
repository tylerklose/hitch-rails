# frozen_string_literal: true

require "hitch/version"
require "hitch/rack_form_guard"
require "hitch/rate_limit_store"
require "hitch/engine"
require "hitch/resource_uri"
require "hitch/pkce"
require "hitch/mcp/configuration"
require "hitch/configuration"
require "hitch/dynamic_registration_rate_limit"

# hitch-rails turns a Rails app into an authorization server implemented
# against the MCP 2026-07-28 authorization profile — OAuth 2.1 + PKCE (S256),
# Resource Indicators with audience binding (RFC 8707), discovery metadata
# (RFC 8414 + RFC 9728), token revocation (RFC 7009), and CORS for
# browser-based MCP clients — plus an authenticated host-mounted MCP endpoint
# with a deny-default tool Registry behind a private Ruby SDK boundary, rate
# limiting counted through the host application's own cache store, sanitized
# observation events, and a read-only operator doctor.
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
    end
  end
end
