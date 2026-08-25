# frozen_string_literal: true

require "uri"

Hitch.configure do |config|
  config.resource_uri = ENV.fetch("HITCH_CONFORMANCE_RESOURCE_URI", "https://dummy.test/mcp")
  resource_host = URI.parse(config.resource_uri).hostname
  config.allowed_hosts = [ "www.example.com", resource_host ].compact.uniq
  config.allowed_origins = [ "https://claude.ai" ]
  config.dynamic_client_registration_enabled = true
  config.client_id_metadata_enabled = ENV["HITCH_CONFORMANCE"] == "1"
  config.brand_name = "Dummy"
  config.mcp.enabled = true
  config.mcp.registry = "McpToolRegistry"
  config.mcp.server_info = {
    name: "hitch-dummy",
    version: "0.2.0",
    title: "Hitch Dummy",
    instructions: "Use only tools available to the signed-in principal."
  }
  config.mcp.scope_resolver = ->(principal:, access_token:, request:) { principal }
  config.mcp.request_limit = {
    to: Integer(ENV.fetch("HITCH_MCP_REQUEST_LIMIT_TO", "120"), 10),
    within: Integer(ENV.fetch("HITCH_MCP_REQUEST_LIMIT_WITHIN", "60"), 10).seconds
  }
  # The dummy test environment runs Rails' :null_store default, which cannot
  # count. Admission tests need a real counter, and the cross-process lane
  # needs one shared between processes.
  config.mcp.rate_limit_store = if ENV["HITCH_MCP_REDIS_URL"]
    ActiveSupport::Cache::RedisCacheStore.new(url: ENV.fetch("HITCH_MCP_REDIS_URL"))
  else
    ActiveSupport::Cache::MemoryStore.new
  end
  config.mcp.max_request_bytes = 1_024
  config.mcp.max_result_bytes = 1_024
end

# A real production hitch:doctor subprocess drives each feature-specific
# store. This one looks shared to the class-level posture check but lies about
# the second increment, proving Doctor exercises the counting contract itself.
if (doctor_probe = ENV["HITCH_DOCTOR_STORE_PROBE"])
  Hitch.const_set(:DoctorProbeStore, Class.new(ActiveSupport::Cache::Store) do
    def initialize(secret)
      super()
      @secret = secret
    end

    def increment(_name, _amount = 1, **) = 1
    def delete(_name, _options = nil) = true
    def inspect = @secret
  end)
  doctor_store = Hitch::DoctorProbeStore.new(ENV.fetch("HITCH_DOCTOR_STORE_SECRET"))

  Hitch.configure do |config|
    config.mcp.enabled = false
    config.dynamic_client_registration_enabled = doctor_probe == "dcr"
    config.device_authorization_enabled = doctor_probe == "device"
    config.dynamic_client_registration_rate_store = doctor_store if doctor_probe == "dcr"
    config.device_authorization_rate_store = doctor_store if doctor_probe == "device"
  end
end

# Boot probe for the production-only rate-limit-store checks. Every other test
# in this suite configures mcp.rate_limit_store explicitly, above — so the fall
# back to the application's own cache store, which is what every adopter gets
# by default, is exercised nowhere else. That gap is how a boot-killing
# regression shipped once already.
if ENV["HITCH_BOOT_PROBE"]
  shared_store = Class.new(ActiveSupport::Cache::Store) do
    def increment(name, amount = 1, **options) = amount
  end

  Hitch.configure do |config|
    config.mcp.rate_limit_store = nil
    # Leaves exactly one boot check running, so a failure names the setting
    # under test rather than whichever check happened to run first.
    config.dynamic_client_registration_enabled = false
  end
  Rails.application.config.action_controller.cache_store =
    if ENV["HITCH_BOOT_PROBE"] != "shared"
      ActiveSupport::Cache::MemoryStore.new
    elsif ENV["HITCH_MCP_REDIS_URL"]
      # bin/ci-rate-limit supplies a real Redis. The synthetic store below
      # satisfies the same predicate, but only a real one proves the fallback
      # resolves something a production deployment would actually count with.
      ActiveSupport::Cache::RedisCacheStore.new(url: ENV.fetch("HITCH_MCP_REDIS_URL"))
    else
      shared_store.new
    end
end
