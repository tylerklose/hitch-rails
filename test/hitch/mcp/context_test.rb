# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "json"
require "securerandom"

class Hitch::MCP::ContextTest < ActiveSupport::TestCase
  test "untrusted meta is recursively copied and frozen" do
    principal = Object.new
    access_token = Object.new
    scope = Object.new
    nested_value = +"original"
    mutable_key = +"nested"
    metadata = {
      mutable_key => [ { "value" => nested_value } ],
      "number" => 7.5,
      "true" => true,
      "false" => false,
      "null" => nil,
      "principal" => "attacker-principal",
      "access_token" => "attacker-token",
      "scope" => "attacker-scope",
      "client_id" => "attacker-client",
      "resource" => "https://attacker.test/mcp"
    }
    scopes = [ +"mcp", +"read" ]

    context = build_context(
      principal:,
      access_token:,
      scope:,
      granted_scopes: scopes,
      meta: metadata
    )
    source_nested_key = metadata.keys.find { |key| key == "nested" }
    copied_nested_key = context.meta.keys.find { |key| key == "nested" }

    mutable_key.replace("changed-key")
    nested_value.replace("changed-value")
    scopes.first.replace("changed-scope")
    metadata["new"] = "late mutation"

    assert_predicate context, :frozen?
    assert_same principal, context.principal
    assert_same access_token, context.access_token
    assert_same scope, context.scope
    assert_equal %w[mcp read], context.granted_scopes
    assert_equal "original", context.meta.dig("nested", 0, "value")
    assert_equal [ 7.5, true, false, nil ], context.meta.values_at("number", "true", "false", "null")
    refute_same source_nested_key, copied_nested_key
    refute context.meta.key?("new")
    assert_deeply_frozen context.granted_scopes
    assert_deeply_frozen context.meta

    assert_equal "host-client", context.client_id
    assert_equal "https://host.test/mcp", context.resource
    refute_equal context.meta.fetch("principal"), context.principal
    refute_equal context.meta.fetch("access_token"), context.access_token
    refute_equal context.meta.fetch("scope"), context.scope
    refute_equal context.meta.fetch("client_id"), context.client_id
    refute_equal context.meta.fetch("resource"), context.resource
  end

  test "authority references stay opaque while scalar readers are copied" do
    principal = Object.new
    access_token = Object.new
    scope = Object.new
    client_id = +"host-client"
    resource = +"https://host.test/mcp"
    request_id = +"request-42"
    remote_ip = +"198.51.100.42"
    user_agent = +"context-test"
    protocol_version = +"2026-07-28"

    context = build_context(
      principal:,
      access_token:,
      scope:,
      client_id:,
      resource:,
      request_id:,
      remote_ip:,
      user_agent:,
      protocol_version:
    )

    assert_same principal, context.principal
    assert_same access_token, context.access_token
    assert_same scope, context.scope
    refute_predicate principal, :frozen?
    refute_predicate access_token, :frozen?
    refute_predicate scope, :frozen?

    [ client_id, resource, request_id, remote_ip, user_agent, protocol_version ].each do |source|
      source.replace("mutated")
    end

    assert_equal "host-client", context.client_id
    assert_equal "https://host.test/mcp", context.resource
    assert_equal "request-42", context.request_id
    assert_equal "198.51.100.42", context.remote_ip
    assert_equal "context-test", context.user_agent
    assert_equal "2026-07-28", context.protocol_version
  end

  test "construction rejects values outside the framework envelope" do
    assert_raises(ArgumentError) { build_context(principal: nil) }
    assert_raises(ArgumentError) { build_context(access_token: nil) }
    assert_raises(ArgumentError) { build_context(granted_scopes: "mcp") }
    assert_raises(ArgumentError) { build_context(client_id: "") }
    assert_raises(ArgumentError) { build_context(request_id: nil) }
    assert_raises(ArgumentError) { build_context(user_agent: 7) }
    assert_context_error("meta must be a Hash") { build_context(meta: []) }
    assert_context_error("meta keys must be Strings") { build_context(meta: { 7 => "unsupported" }) }
    assert_context_error("meta must contain only JSON values") do
      build_context(meta: { "unsupported" => Object.new })
    end

    string_subclass = Class.new(String)
    subclass_key = string_subclass.new("subclass")
    subclass_value = string_subclass.new("value")
    identity_hash = {}.compare_by_identity
    identity_hash[subclass_key] = subclass_value
    context = build_context(meta: identity_hash)
    assert_equal({ "subclass" => "value" }, context.meta)
    assert_instance_of string_subclass, context.meta.keys.fetch(0)
    assert_instance_of string_subclass, context.meta.fetch("subclass")
  end

  private

  def build_context(**overrides)
    Hitch::MCP::Context.new(**{
      principal: Object.new,
      access_token: Object.new,
      scope: nil,
      granted_scopes: [ "mcp" ],
      client_id: "host-client",
      resource: "https://host.test/mcp",
      request_id: "request-42",
      remote_ip: "198.51.100.42",
      user_agent: nil,
      protocol_version: "2026-07-28",
      meta: {}
    }.merge(overrides))
  end

  def assert_deeply_frozen(value)
    assert_predicate value, :frozen?
    case value
    when Hash
      value.each do |key, child|
        assert_predicate key, :frozen?
        assert_deeply_frozen(child)
      end
    when Array
      value.each { |child| assert_deeply_frozen(child) }
    end
  end

  def assert_context_error(message)
    error = assert_raises(ArgumentError) { yield }
    assert_equal message, error.message
  end
end

class Hitch::MCP::ContextEndpointTest < ActionDispatch::IntegrationTest
  RESOURCE = "https://dummy.test/mcp"
  PROTOCOL_VERSION = "2026-07-28"

  setup do
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    User.delete_all
    Hitch.reset_configuration!
    @contexts = []
    Hitch.configure do |configuration|
      configuration.resource_uri = RESOURCE
      configuration.allowed_hosts = []
      configuration.allowed_origins = []
      configuration.supported_scopes = %w[mcp read]
      configuration.mcp.registry = "McpToolRegistry"
      configuration.mcp.server_info = lambda { |context|
        @contexts << context
        { name: "hitch-context", version: "0.2.0" }
      }
      configuration.mcp.scope_resolver = ->(principal:, access_token:, request:) { nil }
      configuration.mcp.request_limit = { to: 120, within: 60 }
    end
    Hitch.configuration.validate!
    Hitch.configuration.mcp.prepare_registry!(supported_scopes: Hitch.configuration.supported_scopes)
  end

  teardown do
    Hitch.reset_configuration!
  end

  test "endpoint creates an isolated public Context with optional client info" do
    first_user = User.create!(email: "context-one@example.test")
    second_user = User.create!(email: "context-two@example.test")
    first_token = mint_token(first_user, client_id: "client-one", scopes: "mcp read")
    second_token = mint_token(second_user, client_id: "client-two", scopes: "mcp")

    first_meta = required_meta.merge(
      "io.modelcontextprotocol/clientInfo" => {
        "name" => "Context Client",
        "version" => "1.0",
        "icons" => [ { "src" => "https://client.test/icon.png", "sizes" => [ "32x32" ] } ]
      },
      "principal" => "attacker-principal",
      "access_token" => "attacker-token",
      "scope" => "attacker-scope",
      "client_id" => "attacker-client",
      "resource" => "https://attacker.test/mcp"
    )
    post_discover(first_token, "first", first_meta, remote_ip: "198.51.100.10")
    assert_response :ok

    post_discover(second_token, "second", required_meta, remote_ip: "198.51.100.11")
    assert_response :ok

    assert_equal 2, @contexts.length
    first, second = @contexts
    assert_instance_of Hitch::MCP::Context, first
    assert_instance_of Hitch::MCP::Context, second
    refute_same first, second
    refute_same first.meta, second.meta
    refute_same first.granted_scopes, second.granted_scopes

    assert_equal first_user.id, first.principal.id
    assert_equal second_user.id, second.principal.id
    assert_equal "client-one", first.client_id
    assert_equal "client-two", second.client_id
    assert_equal %w[mcp read], first.granted_scopes
    assert_equal [ "mcp" ], second.granted_scopes
    assert_nil first.scope
    assert_nil second.scope
    assert_equal RESOURCE, first.resource
    assert_equal "context-first", first.request_id
    assert_equal "198.51.100.10", first.remote_ip
    assert_equal "hitch-context-test", first.user_agent
    assert_equal PROTOCOL_VERSION, first.protocol_version
    assert_equal "Context Client",
      first.meta.dig("io.modelcontextprotocol/clientInfo", "name")
    refute second.meta.key?("io.modelcontextprotocol/clientInfo")

    refute_equal first.meta.fetch("principal"), first.principal
    refute_equal first.meta.fetch("access_token"), first.access_token
    refute_equal first.meta.fetch("scope"), first.scope
    refute_equal first.meta.fetch("client_id"), first.client_id
    refute_equal first.meta.fetch("resource"), first.resource
  end

  private

  def required_meta
    {
      "io.modelcontextprotocol/protocolVersion" => PROTOCOL_VERSION,
      "io.modelcontextprotocol/clientCapabilities" => {}
    }
  end

  def post_discover(token, id, meta, remote_ip:)
    body = {
      "jsonrpc" => "2.0",
      "id" => "context-#{id}",
      "method" => "server/discover",
      "params" => { "_meta" => meta }
    }
    post "/mcp", params: JSON.generate(body), headers: {
      "Host" => "dummy.test",
      "Authorization" => "Bearer #{token}",
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream",
      "MCP-Protocol-Version" => PROTOCOL_VERSION,
      "Mcp-Method" => "server/discover",
      "User-Agent" => "hitch-context-test",
      "REMOTE_ADDR" => remote_ip
    }
  end

  def mint_token(user, client_id:, scopes:)
    verifier = SecureRandom.urlsafe_base64(64)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    record = Hitch::AccessToken.create_authorization!(
      principal: user,
      client_id:,
      client_name: "Context Client",
      code_challenge: challenge,
      code_challenge_method: "S256",
      scopes:,
      resource_uri: RESOURCE
    )
    exchange_authorization_code(record, verifier:)
  end
end
