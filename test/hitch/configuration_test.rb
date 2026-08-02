# frozen_string_literal: true

require "test_helper"

class Hitch::ConfigurationTest < ActiveSupport::TestCase
  setup { Hitch.reset_configuration! }
  teardown { Hitch.reset_configuration! }

  test "resource URI assignment uses the canonical OAuth resource path" do
    Hitch.configuration.resource_uri = "HTTPS://Example.COM:443/mcp"

    assert_equal "https://example.com/mcp", Hitch.configuration.resource_uri
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
