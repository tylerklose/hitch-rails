# frozen_string_literal: true

require "test_helper"

class Hitch::ConfigurationTest < ActiveSupport::TestCase
  setup { Hitch.reset_configuration! }
  teardown { Hitch.reset_configuration! }

  test "resource URI assignment uses the canonical OAuth resource path" do
    Hitch.configuration.resource_uri = "HTTPS://Example.COM:443/mcp"

    assert_equal "https://example.com/mcp", Hitch.configuration.resource_uri
  end

  test "MCP configuration has one stable top-level authority" do
    configuration = Hitch.configuration

    assert_instance_of Hitch::MCP::Configuration, configuration.mcp
    assert_same configuration.mcp, Hitch.configuration.mcp
    assert configuration.mcp.validate!
    configuration.mcp.server_info = ->(_context) { { name: "example", version: "1" } }
    assert_raises(ArgumentError) { configuration.mcp.validate! }
    configuration.mcp.registry = "McpToolRegistry"
    assert_raises(ArgumentError) { configuration.mcp.validate! }
    configuration.mcp.scope_resolver = ->(principal:, access_token:, request:) { nil }
    assert_raises(ArgumentError) { configuration.mcp.validate! }
    configuration.mcp.request_limit = { to: 120, within: 1.minute }
    assert configuration.mcp.validate!
  end

  test "MCP endpoint configuration validates callable server info and integer byte caps" do
    configuration = Hitch.configuration.mcp
    server_info = ->(_context) { { name: "example", version: "1" } }

    configuration.server_info = server_info
    configuration.max_request_bytes = 2_048
    configuration.max_result_bytes = 4_096

    assert_same server_info, configuration.server_info
    assert_equal 2_048, configuration.max_request_bytes
    assert_equal 4_096, configuration.max_result_bytes
    assert_raises(ArgumentError) { configuration.server_info = { name: "example" } }
    [ 0, -1, 1.0, "1024", nil ].each do |invalid|
      assert_raises(ArgumentError) { configuration.max_request_bytes = invalid }
      assert_raises(ArgumentError) { configuration.max_result_bytes = invalid }
    end
  end

  test "MCP request byte cap has one explicit development default" do
    assert_equal 1_048_576, Hitch.configuration.mcp.max_request_bytes
    assert_equal 1_048_576, Hitch.configuration.mcp.max_result_bytes
    assert_nil Hitch.configuration.mcp.registry
    assert_nil Hitch.configuration.mcp.server_info
    assert_nil Hitch.configuration.mcp.scope_resolver
    assert_nil Hitch.configuration.mcp.request_limit
    assert_same ActionController::Base.cache_store, Hitch.configuration.mcp.rate_limit_store
  end

  test "MCP request limit normalizes a copied whole-second fixed window" do
    source = { "to" => 12, "within" => 2.minutes }
    Hitch.configuration.mcp.request_limit = source
    source["to"] = 99

    assert_equal({ to: 12, within: 120 }, Hitch.configuration.mcp.request_limit)
    assert_predicate Hitch.configuration.mcp.request_limit, :frozen?

    invalid = [
      nil,
      {},
      { to: 1 },
      { to: 1, within: 60, extra: true },
      { to: 1, "to" => 2, within: 60 },
      { to: 0, within: 60 },
      { to: 1.0, within: 60 },
      { to: 1, within: 0 },
      { to: 1, within: 1.5 },
      { to: 1, within: 1.5.seconds }
    ]
    invalid.each do |value|
      assert_raises(ArgumentError, value.inspect) do
        Hitch.configuration.mcp.request_limit = value
      end
    end
  end

  test "MCP rate limit store accepts any cache store and rejects one that cannot count" do
    store = ActiveSupport::Cache::MemoryStore.new
    Hitch.configuration.mcp.rate_limit_store = store

    assert_same store, Hitch.configuration.mcp.rate_limit_store

    [ Object.new, "redis://redis.example.test/0", 42 ].each do |value|
      assert_raises(ArgumentError, value.inspect) do
        Hitch.configuration.mcp.rate_limit_store = value
      end
    end
  end

  test "production MCP runtime refuses a store that cannot count across processes" do
    configuration = Hitch.configuration.mcp
    configuration.registry = "McpToolRegistry"
    configuration.server_info = ->(_context) { { name: "example", version: "1" } }
    configuration.scope_resolver = ->(principal:, access_token:, request:) { principal }
    configuration.request_limit = { to: 10, within: 60 }
    configuration.rate_limit_store = ActiveSupport::Cache::MemoryStore.new
    production = ActiveSupport::EnvironmentInquirer.new("production")

    stub_class_method(Rails, :env, -> { production }) do
      # Booting needs no store at all; only the resolved store is constrained.
      assert configuration.validate!

      error = assert_raises(ArgumentError) { configuration.validate_rate_limit_store! }
      assert_includes error.message, "cannot count one"

      configuration.rate_limit_store = Class.new(ActiveSupport::Cache::Store) do
        def increment(name, amount = 1, **options) = 1
      end.new
      assert configuration.validate_rate_limit_store!
    end
  end

  test "resource URI and supported scopes have explicit persistence-work bounds" do
    too_long_resource = "https://example.test/#{'x' * Hitch::Configuration::MAX_RESOURCE_URI_BYTES}"
    assert_raises(Hitch::ResourceUri::Invalid) do
      Hitch.configuration.resource_uri = too_long_resource
    end

    assert_raises(ArgumentError) { Hitch.configuration.supported_scopes = [] }
    assert_raises(ArgumentError) { Hitch.configuration.supported_scopes = [ "mcp", "mcp" ] }
    assert_raises(ArgumentError) do
      Hitch.configuration.supported_scopes = [ "x" * (Hitch::Configuration::MAX_SCOPE_BYTES + 1) ]
    end
    assert_raises(ArgumentError) do
      Hitch.configuration.supported_scopes = Array.new(Hitch::Configuration::MAX_SCOPES + 1) { |index| "s#{index}" }
    end
    assert_raises(ArgumentError) do
      Hitch.configuration.supported_scopes = 5.times.map { |index| "s#{index}-#{'x' * 58}" }
    end
  end

  test "configuration validation gives one actionable missing-resource error" do
    error = assert_raises(ArgumentError) { Hitch.configuration.validate! }

    assert_includes error.message, "resource_uri is required"
  end

  test "test accepts loopback HTTP while production rejects it" do
    Hitch.configuration.resource_uri = "http://127.0.0.1:3000/mcp"
    assert_equal "http://127.0.0.1:3000/mcp", Hitch.configuration.resource_uri

    production = ActiveSupport::EnvironmentInquirer.new("production")
    stub_class_method(Rails, :env, -> { production }) do
      assert_raises(Hitch::ResourceUri::Invalid) do
        Hitch.configuration.resource_uri = "http://127.0.0.1:3000/mcp"
      end
    end
  end

  test "hosts and origins reject URL-shaped or noncanonical entries" do
    assert_raises(ArgumentError) { Hitch.configuration.allowed_hosts = [ "https://example.com" ] }
    assert_raises(ArgumentError) { Hitch.configuration.allowed_hosts = [ "example.com:443" ] }
    assert_raises(ArgumentError) { Hitch.configuration.allowed_origins = [ "https://example.com/path" ] }
    assert_raises(ArgumentError) { Hitch.configuration.allowed_origins = [ "https://EXAMPLE.com" ] }
  end

  test "security configuration copies and deeply freezes caller strings" do
    resource = +"https://example.com/mcp"
    hosts = [ +"proxy.example" ]
    origins = [ +"https://client.example" ]
    scopes = [ +"mcp" ]

    Hitch.configure do |configuration|
      configuration.resource_uri = resource
      configuration.allowed_hosts = hosts
      configuration.allowed_origins = origins
      configuration.supported_scopes = scopes
    end

    resource.replace("https://attacker.example/mcp")
    hosts.first.replace("attacker.example")
    origins.first.replace("https://attacker.example")
    scopes.first.replace("admin")

    configuration = Hitch.configuration
    assert_equal "https://example.com/mcp", configuration.resource_uri
    assert_equal [ "proxy.example" ], configuration.allowed_hosts
    assert_equal [ "https://client.example" ], configuration.allowed_origins
    assert_equal [ "mcp" ], configuration.supported_scopes
    assert configuration.resource_uri.frozen?
    assert configuration.allowed_hosts.first.frozen?
    assert configuration.allowed_origins.first.frozen?
    assert configuration.supported_scopes.first.frozen?
  end

  test "DCR preserves the library fallback but tracks explicit posture" do
    configuration = Hitch.configuration

    assert configuration.dynamic_client_registration_enabled
    refute configuration.dynamic_client_registration_enabled_configured?

    configuration.dynamic_client_registration_enabled = false
    refute configuration.dynamic_client_registration_enabled
    assert configuration.dynamic_client_registration_enabled_configured?
  end

  test "DCR limit requires positive integer to and within values" do
    Hitch.configuration.dynamic_client_registration_limit = { to: "5", within: 30.seconds }
    assert_equal({ to: 5, within: 30 }, Hitch.configuration.dynamic_client_registration_limit)

    assert_raises(ArgumentError) do
      Hitch.configuration.dynamic_client_registration_limit = { to: 0, within: 60 }
    end
    assert_raises(ArgumentError) do
      Hitch.configuration.dynamic_client_registration_limit = { to: 5, within: 1.5 }
    end
  end
end
