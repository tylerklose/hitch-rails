# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "json"
require "securerandom"
require "hitch/mcp/test_helper"

module HitchMcpListingFixtures
  INPUT_SCHEMA = {
    type: "object",
    properties: { message: { type: "string" } },
    additionalProperties: false
  }.freeze

  class Alpha < Hitch::MCP::Tool
    tool_name "alpha.tool"
    description "Always-visible alpha tool"
    input_schema INPUT_SCHEMA

    def self.available_to?(_context) = true
  end

  class Zeta < Hitch::MCP::Tool
    tool_name "zeta.tool"
    description "Always-visible zeta tool"
    input_schema INPUT_SCHEMA

    def self.available_to?(_context) = true
  end

  class Admin < Hitch::MCP::Tool
    tool_name "admin.tool"
    description "Visible tool requiring a static admin scope"
    input_schema INPUT_SCHEMA

    def self.available_to?(_context) = true
  end

  class HiddenAdmin < Hitch::MCP::Tool
    tool_name "hidden.admin"
    description "Unavailable tool whose scopes must remain private"
    input_schema INPUT_SCHEMA

    def self.available_to?(_context) = false
  end

  class DefaultDenied < Hitch::MCP::Tool
    tool_name "default.denied"
    description "Tool relying on Hitch's deny-default availability"
    input_schema INPUT_SCHEMA
  end

  class PrincipalAlpha < Hitch::MCP::Tool
    tool_name "principal.alpha"
    description "Tool visible only to the alpha principal"
    input_schema INPUT_SCHEMA

    def self.available_to?(context) = context.scope == "alpha@example.test"
  end

  class PrincipalBeta < Hitch::MCP::Tool
    tool_name "principal.beta"
    description "Tool visible only to the beta principal"
    input_schema INPUT_SCHEMA

    def self.available_to?(context) = context.scope == "beta@example.test"
  end

  class Raising < Hitch::MCP::Tool
    tool_name "raising.tool"
    description "Tool with a failing host availability predicate"
    input_schema INPUT_SCHEMA

    def self.available_to?(_context) = raise("availability-secret")
  end

  class NonBoolean < Hitch::MCP::Tool
    tool_name "nonboolean.tool"
    description "Tool with an invalid availability result"
    input_schema INPUT_SCHEMA

    def self.available_to?(_context) = nil
  end

  class Concurrent < Hitch::MCP::Tool
    tool_name "concurrent.tool"
    description "Tool used to overlap two principal-specific requests"
    input_schema INPUT_SCHEMA

    class << self
      attr_accessor :barrier

      def available_to?(context)
        barrier&.wait
        context.scope == "alpha@example.test"
      end
    end
  end

  class MainRegistry < Hitch::MCP::Registry
    register Zeta, scopes: [ "mcp" ]
    register HiddenAdmin, scopes: %w[mcp admin]
    register DefaultDenied, scopes: [ "mcp" ]
    register Admin, scopes: %w[mcp admin]
    register Alpha, scopes: [ "mcp" ]
  end

  class PrincipalRegistry < Hitch::MCP::Registry
    register PrincipalBeta, scopes: [ "mcp" ]
    register DefaultDenied, scopes: [ "mcp" ]
    register PrincipalAlpha, scopes: [ "mcp" ]
  end

  class RaisingRegistry < Hitch::MCP::Registry
    register Raising, scopes: [ "mcp" ]
  end

  class NonBooleanRegistry < Hitch::MCP::Registry
    register NonBoolean, scopes: [ "mcp" ]
  end

  class ConcurrentRegistry < Hitch::MCP::Registry
    register Concurrent, scopes: [ "mcp" ]
  end
end

module HitchMcpListingReloadFixtures
end

class MCPListingTest < ActionDispatch::IntegrationTest
  # The suite drives listings through the same public helper hosts use.
  include Hitch::MCP::TestHelper

  RESOURCE = "https://dummy.test/mcp"

  self.use_transactional_tests = false

  class Barrier
    def initialize(parties)
      @parties = parties
      @arrived = 0
      @mutex = Mutex.new
      @condition = ConditionVariable.new
    end

    def wait
      @mutex.synchronize do
        @arrived += 1
        @condition.broadcast if @arrived == @parties
        @condition.wait(@mutex) while @arrived < @parties
      end
    end
  end

  setup do
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    User.delete_all
    Hitch.reset_configuration!
    McpController.wire_slice_enabled = false
    @resolver_calls = []
    @resolver_mutex = Mutex.new
    configure_runtime("HitchMcpListingFixtures::MainRegistry")
    @alpha = User.create!(email: "alpha@example.test")
    @beta = User.create!(email: "beta@example.test")
    @alpha_mcp = mint_token(@alpha, scopes: "mcp")
    @alpha_admin = mint_token(@alpha, scopes: "mcp admin")
    @beta_mcp = mint_token(@beta, scopes: "mcp")
  end

  teardown do
    HitchMcpListingFixtures::Concurrent.barrier = nil
    clear_listing_reload_fixtures
    McpController.wire_slice_enabled = false
    Hitch.reset_configuration!
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    User.delete_all
  end

  test "listing is deterministic and filters static scopes after availability" do
    post_mcp(method: "tools/list", token: @alpha_mcp)

    assert_response :ok
    result = JSON.parse(response.body).fetch("result")
    assert_equal %w[alpha.tool zeta.tool], result.fetch("tools").map { |tool| tool.fetch("name") }
    assert_equal "private", result.fetch("cacheScope")
    assert_equal 0, result.fetch("ttlMs")
    assert_equal "complete", result.fetch("resultType")
    assert_equal 1, @resolver_calls.length
    assert_equal @alpha, @resolver_calls.fetch(0).fetch(:principal)
    assert_instance_of ActionDispatch::Request, @resolver_calls.fetch(0).fetch(:request)

    post_mcp(method: "tools/list", token: @alpha_admin)
    names = JSON.parse(response.body).dig("result", "tools").map { |tool| tool.fetch("name") }
    assert_equal %w[admin.tool alpha.tool zeta.tool], names
  end

  test "availability is deny default and request local" do
    configure_runtime("HitchMcpListingFixtures::PrincipalRegistry")

    post_mcp(method: "tools/list", token: @alpha_mcp)
    assert_equal [ "principal.alpha" ], listed_names(response)

    post_mcp(method: "tools/list", token: @beta_mcp)
    assert_equal [ "principal.beta" ], listed_names(response)

    post_mcp(method: "tools/list", token: @alpha_mcp)
    assert_equal [ "principal.alpha" ], listed_names(response)
    assert_equal 3, @resolver_calls.length
  end

  test "unknown and unavailable calls are indistinguishable before static scope step-up" do
    unknown = call_snapshot("missing.tool")
    unavailable = call_snapshot("hidden.admin")

    assert_equal unknown, unavailable
    assert_equal 200, unknown.fetch(:status)
    assert_equal(-32602, JSON.parse(unknown.fetch(:body)).dig("error", "code"))
    refute_includes unknown.fetch(:headers).to_s, "admin"
    refute_includes unknown.fetch(:body), "hidden"

    McpController.reset_wire_metrics!
    post_mcp(
      method: "tools/call",
      token: @alpha_mcp,
      id: "same-call",
      params: { name: "admin.tool", arguments: { message: "hello" } }
    )

    assert_response :forbidden
    assert_predicate response.body, :blank?
    challenge = response.headers.fetch("WWW-Authenticate")
    assert_includes challenge, 'error="insufficient_scope"'
    assert_includes challenge, 'scope="mcp admin"'
    assert_includes challenge, "resource_metadata="
    assert_includes response.headers.fetch("Access-Control-Expose-Headers"), "WWW-Authenticate"
    assert_equal 0, McpController.wire_metrics.fetch(:sdk, 0)
  end

  test "the initial bearer challenge requests only the base scope" do
    # Raw post: the helper refuses an absent bearer token by design.
    post "/mcp", params: "{}",
      headers: { "Host" => "dummy.test", "Content-Type" => "application/json" }

    assert_response :unauthorized
    challenge = response.headers.fetch("WWW-Authenticate")
    assert_includes challenge, 'scope="mcp"'
    refute_includes challenge, "admin"
    assert_includes challenge,
      'resource_metadata="https://dummy.test/.well-known/oauth-protected-resource/mcp"'
  end

  test "a raising scope resolver fails closed before registry and sdk work" do
    Hitch.configuration.mcp.scope_resolver = lambda do |principal:, access_token:, request:|
      raise "resolver-secret"
    end
    McpController.reset_wire_metrics!

    post_mcp(method: "tools/list", token: @alpha_mcp)

    assert_response :ok
    assert_equal(-32603, JSON.parse(response.body).dig("error", "code"))
    refute_includes response.body, "resolver-secret"
    assert_equal 0, McpController.wire_metrics.fetch(:registry, 0)
    assert_equal 0, McpController.wire_metrics.fetch(:sdk, 0)
  end

  test "an unset scope resolver resolves a nil scope and lists normally" do
    Hitch.configuration.mcp.scope_resolver = nil

    post_mcp(method: "tools/list", token: @alpha_mcp)

    assert_response :ok
    body = JSON.parse(response.body)
    assert_nil body["error"]
    assert_equal %w[alpha.tool zeta.tool],
      body.dig("result", "tools").map { |tool| tool.fetch("name") }
  end

  test "raising and nonboolean availability fail closed without details" do
    {
      "HitchMcpListingFixtures::RaisingRegistry" => "availability-secret",
      "HitchMcpListingFixtures::NonBooleanRegistry" => "nonboolean"
    }.each do |registry, canary|
      configure_runtime(registry)
      McpController.reset_wire_metrics!

      post_mcp(method: "tools/list", token: @alpha_mcp)

      assert_response :ok
      assert_equal(-32603, JSON.parse(response.body).dig("error", "code"))
      refute_includes response.body, canary
      assert_equal 1, McpController.wire_metrics.fetch(:registry, 0)
      assert_equal 0, McpController.wire_metrics.fetch(:sdk, 0)
    end
  end

  test "client info is optional and cannot change authority" do
    post_mcp(method: "tools/list", token: @alpha_mcp)
    without_client_info = listed_names(response)

    post_mcp(
      method: "tools/list",
      token: @alpha_mcp,
      client_info: { "name" => "Synthetic Client", "version" => "1" }
    )

    assert_equal without_client_info, listed_names(response)
    assert_equal [ @alpha, @alpha ], @resolver_calls.last(2).map { |call| call.fetch(:principal) }
  end

  test "host scope resolution cannot rewrite the validated token scope snapshot" do
    Hitch.configuration.mcp.scope_resolver = lambda do |principal:, access_token:, request:|
      access_token.scopes = "mcp admin"
      principal.email
    end

    post_mcp(method: "tools/list", token: @alpha_mcp)

    assert_response :ok
    assert_equal %w[alpha.tool zeta.tool], listed_names(response)
  end

  test "a nil host scope is valid when the resolver itself is present" do
    Hitch.configuration.mcp.scope_resolver = lambda do |principal:, access_token:, request:|
      nil
    end

    post_mcp(method: "tools/list", token: @alpha_mcp)

    assert_response :ok
    assert_equal %w[alpha.tool zeta.tool], listed_names(response)
  end

  test "simultaneous principals do not share scope or availability" do
    configure_runtime("HitchMcpListingFixtures::ConcurrentRegistry")
    HitchMcpListingFixtures::Concurrent.barrier = Barrier.new(2)
    # Force Rails' lazy route set to load before the requests race. Otherwise
    # one thread can transiently observe an empty route set while the other is
    # loading it, producing a false 404 instead of exercising Hitch isolation.
    Rails.application.routes.routes.to_a

    responses = Queue.new
    threads = [ [ @alpha_mcp, "alpha" ], [ @beta_mcp, "beta" ] ].map do |token, label|
      Thread.new do
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.extend(Hitch::MCP::TestHelper)
        session.https!
        session.host! "dummy.test"
        result = session.post_mcp(method: "tools/list", token: token, id: label)
        responses << [ label, result.status, JSON.parse(result.body) ]
      rescue StandardError => error
        responses << [ label, :error, error ]
      end
    end
    threads.each do |thread|
      assert thread.join(5), "simultaneous listing request did not finish"
    end

    results = 2.times.to_h do
      label, status, result = responses.pop
      assert_equal 200, status, result.inspect
      [ label, result.dig("result", "tools").map { |tool| tool.fetch("name") } ]
    end
    assert_equal [ "concurrent.tool" ], results.fetch("alpha")
    assert_equal [], results.fetch("beta")
    assert_equal %w[alpha@example.test beta@example.test],
      @resolver_calls.last(2).map { |call| call.fetch(:principal).email }.sort
  end

  test "a request overlapping reload waits and uses only the new current class" do
    old_tool = define_listing_reload_pair(available: true, description: "old listing tool")
    configure_runtime("HitchMcpListingReloadFixtures::Registry")
    post_mcp(method: "tools/list", token: @alpha_mcp)
    assert_equal [ "reload.tool" ], listed_names(response)

    clear_listing_reload_fixtures
    entered = Queue.new
    release = Queue.new
    new_tool = define_listing_reload_pair(
      available: false,
      description: "new listing tool",
      description_gate: [ entered, release ]
    )
    refute_same old_tool, new_tool

    prepare_result = Queue.new
    prepare_thread = Thread.new do
      prepare_registry
      prepare_result << :ok
    rescue StandardError => error
      prepare_result << error
    end
    entered.pop

    request_result = Queue.new
    request_thread = Thread.new do
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.extend(Hitch::MCP::TestHelper)
      session.https!
      session.host! "dummy.test"
      result = session.post_mcp(method: "tools/list", token: @alpha_mcp, id: "reload-overlap")
      request_result << [ result.status, result.body ]
    rescue StandardError => error
      request_result << error
    end
    assert_nil request_thread.join(0.05),
      "request must wait while the replacement snapshot owns the registry lock"

    release << true
    prepare_thread.join
    request_thread.join
    assert_equal :ok, prepare_result.pop
    status, body = request_result.pop
    assert_equal 200, status
    assert_equal [], JSON.parse(body).dig("result", "tools")
    assert_same new_tool, HitchMcpListingReloadFixtures.const_get(:Tool, false)
  ensure
    release << true if defined?(release) && release.empty?
    prepare_thread&.join
    request_thread&.join
  end

  private

  def configure_runtime(registry_name)
    Hitch.configure do |configuration|
      configuration.resource_uri = RESOURCE
      configuration.allowed_hosts = []
      configuration.allowed_origins = []
      configuration.supported_scopes = %w[mcp admin]
      configuration.mcp.registry = registry_name
      configuration.mcp.server_info = { name: "hitch-listing", version: "0.2.0" }
      configuration.mcp.scope_resolver = lambda do |principal:, access_token:, request:|
        @resolver_mutex.synchronize do
          @resolver_calls << { principal:, access_token:, request: }
        end
        principal.email.dup.freeze
      end
      configuration.mcp.request_limit = { to: 120, within: 60 }
      configuration.mcp.max_request_bytes = 8_192
    end
    Hitch.configuration.validate!
    prepare_registry
  end

  def prepare_registry
    Hitch.configuration.mcp.prepare_registry!(supported_scopes: Hitch.configuration.supported_scopes)
  end

  def define_listing_reload_pair(available:, description:, description_gate: nil)
    tool = Class.new(Hitch::MCP::Tool)
    HitchMcpListingReloadFixtures.const_set(:Tool, tool)
    tool.tool_name "reload.tool"
    tool.description description
    tool.input_schema HitchMcpListingFixtures::INPUT_SCHEMA
    tool.define_singleton_method(:available_to?) { |_context| available }
    if description_gate
      entered, release = description_gate
      tool.define_singleton_method(:description) do
        entered << true
        release.pop
        description
      end
    end

    registry = Class.new(Hitch::MCP::Registry)
    HitchMcpListingReloadFixtures.const_set(:Registry, registry)
    registry.register tool, scopes: [ "mcp" ]
    tool
  end

  def clear_listing_reload_fixtures
    HitchMcpListingReloadFixtures.constants(false).each do |name|
      HitchMcpListingReloadFixtures.send(:remove_const, name)
    end
  end

  def mint_token(principal, scopes:)
    verifier = SecureRandom.urlsafe_base64(64)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    authorization = Hitch::AccessToken.create_authorization!(
      principal: principal,
      client_id: "listing-client",
      client_name: "Listing Client",
      code_challenge: challenge,
      code_challenge_method: "S256",
      scopes: scopes,
      resource_uri: RESOURCE
    )
    exchange_authorization_code(authorization, verifier: verifier)
  end

  def listed_names(integration_response)
    JSON.parse(integration_response.body).dig("result", "tools").map { |tool| tool.fetch("name") }
  end

  def call_snapshot(name)
    McpController.reset_wire_metrics!
    post_mcp(
      method: "tools/call",
      token: @alpha_mcp,
      id: "same-call",
      params: { name: name, arguments: { message: "hello" } }
    )
    {
      status: response.status,
      body: response.body,
      headers: response.headers.slice("WWW-Authenticate", "Access-Control-Expose-Headers")
    }
  end
end
