# frozen_string_literal: true

require "test_helper"
require "active_support/notifications"
require "base64"
require "digest"
require "json"
require "securerandom"

module HitchMcpObservationFixtures
  INPUT_SCHEMA = {
    type: "object",
    properties: { message: { type: "string" } },
    required: [ "message" ],
    additionalProperties: false
  }.freeze

  class Success < Hitch::MCP::Tool
    tool_name "observation.success"
    description "Return one fixed successful result"
    input_schema INPUT_SCHEMA

    def self.available_to?(_context) = true
    def self.authorize!(_context, arguments:) = nil
    def self.perform(_context, arguments:) = Hitch::MCP::Result.text("observation-ok")
  end

  class PolicyDenied < Hitch::MCP::Tool
    tool_name "observation.policy_denied"
    description "Deny after validated arguments"
    input_schema INPUT_SCHEMA

    def self.available_to?(_context) = true
    def self.authorize!(_context, arguments:) = raise(Hitch::MCP::Forbidden, "policy-canary")
  end

  class PolicyFailure < Hitch::MCP::Tool
    tool_name "observation.policy_failure"
    description "Fail unexpectedly during argument policy"
    input_schema INPUT_SCHEMA

    def self.available_to?(_context) = true
    def self.authorize!(_context, arguments:) = raise("policy-failure-canary")
  end

  class HostFailure < Hitch::MCP::Tool
    tool_name "observation.host_failure"
    description "Fail after host execution begins"
    input_schema INPUT_SCHEMA

    def self.available_to?(_context) = true
    def self.authorize!(_context, arguments:) = nil
    def self.perform(_context, arguments:) = raise("host-failure-canary")
  end

  class ExplicitError < Hitch::MCP::Tool
    tool_name "observation.explicit_error"
    description "Return one explicitly safe error"
    input_schema INPUT_SCHEMA

    def self.available_to?(_context) = true
    def self.authorize!(_context, arguments:) = nil
    def self.perform(_context, arguments:) = Hitch::MCP::Result.error("Safe retry guidance")
  end

  class Unavailable < Hitch::MCP::Tool
    tool_name "observation.unavailable"
    description "Remain indistinguishable from an unknown tool"
    input_schema INPUT_SCHEMA

    def self.available_to?(_context) = false
  end

  class Admin < Hitch::MCP::Tool
    tool_name "observation.admin"
    description "Require a static scope before SDK dispatch"
    input_schema INPUT_SCHEMA

    def self.available_to?(_context) = true
  end

  class Registry < Hitch::MCP::Registry
    register Success, scopes: [ "mcp" ]
    register PolicyDenied, scopes: [ "mcp" ]
    register PolicyFailure, scopes: [ "mcp" ]
    register HostFailure, scopes: [ "mcp" ]
    register ExplicitError, scopes: [ "mcp" ]
    register Unavailable, scopes: [ "mcp" ]
    register Admin, scopes: %w[mcp admin]
  end
end

class Hitch::MCP::ObservationTest < ActionDispatch::IntegrationTest
  RUNTIME_TEST_NAMES = %w[
    test_request_event_once_on_every_terminal_path
    test_exact_structural_payloads_correlate_without_raw_identities_or_request_data
    test_identity_HMACs_survive_token_rotation_and_separate_principals_and_clients
    test_invocation_event_records_policy_execution_and_result_categories_only
    test_sensitive_canaries_and_subscriber_failure_are_isolated
  ].freeze
  RESOURCE = "https://dummy.test/mcp"
  PROTOCOL_VERSION = "2026-07-28"
  REQUEST_EVENT_KEYS = %i[
    schema_version request_id method tool_name principal_type principal_key client_key
    http_status protocol_code outcome request_bytes response_bytes duration_ms
  ].freeze
  INVOCATION_EVENT_KEYS = %i[
    schema_version request_id tool_name availability argument_policy executed
    result_category duration_ms
  ].freeze

  class ErrorReporter
    attr_reader :reports

    def initialize
      @reports = []
    end

    def report(error, **options)
      reports << { error:, options: }
    end
  end
  private_constant :ErrorReporter

  setup do
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    User.delete_all
    Hitch.reset_configuration!
    McpController.wire_slice_enabled = false
    configure_runtime
    @user = User.create!(email: "observation-principal@example.test")
    @client_id = "observation-client"
    @token = mint_token(@user, client_id: @client_id)
  end

  teardown do
    McpController.wire_slice_enabled = false
    Hitch.reset_configuration!
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    User.delete_all
  end

  test "request event once on every terminal path" do
    cases = [
      [ "allowed options", 204, nil, 0, 0, -> { options_mcp } ],
      [ "bad host", 400, "bad_request", 1, 0, -> { post_call("observation.success", host: "attacker.test") } ],
      [ "bad origin", 403, "forbidden", 1, 0, -> { post_call("observation.success", origin: "https://attacker.test") } ],
      [ "wrong HTTP method", 405, "method_not_allowed", 1, 0, -> { get_mcp } ],
      [ "missing token", 401, "unauthorized", 1, 0, -> { post_call("observation.success", token: nil) } ],
      [ "rate rejected", 429, "rate_limited", 1, 0, -> { post_call("observation.success", admission: "reject") } ],
      [ "rate store failed", 503, "service_unavailable", 1, 0, -> { post_call("observation.success", admission: "raise") } ],
      [ "unsupported media", 415, "unsupported_media_type", 1, 0, -> { post_call("observation.success", content_type: "text/plain") } ],
      [ "unacceptable response", 406, "not_acceptable", 1, 0, -> { post_call("observation.success", accept: "application/json") } ],
      [ "oversized body", 413, "request_too_large", 1, 0, -> { post_raw("x" * 8_193, method: "tools/list") } ],
      [ "invalid JSON", 400, "parse_error", 1, 0, -> { post_raw("{\"jsonrpc\":", method: "tools/list") } ],
      [ "invalid envelope", 400, "invalid_request", 1, 0, -> { post_raw("[]", method: "tools/list") } ],
      [ "header mismatch", 400, "header_mismatch", 1, 0, -> { post_request(method: "tools/list", header_method: "server/discover") } ],
      [ "unsupported protocol", 400, "unsupported_protocol", 1, 0, -> { post_request(method: "tools/list", protocol_version: "2099-01-01") } ],
      [ "unknown method", 404, "method_not_found", 1, 0, -> { post_request(method: "prompts/list") } ],
      [ "discovery", 200, "complete", 1, 0, -> { post_request(method: "server/discover") } ],
      [ "listing", 200, "complete", 1, 0, -> { post_request(method: "tools/list") } ],
      [ "internal dispatch", 200, "internal_error", 1, 0, -> { post_scope_failure } ],
      [ "unknown tool", 200, "invalid_params", 1, 0, -> { post_call("observation.unknown") } ],
      [ "unavailable tool", 200, "invalid_params", 1, 0, -> { post_call("observation.unavailable") } ],
      [ "static scope", 403, "forbidden", 1, 0, -> { post_call("observation.admin") } ],
      [ "input schema", 200, "complete", 1, 0, -> { post_call("observation.success", arguments: { "message" => 7 }) } ],
      [ "argument policy", 200, "complete", 1, 1, -> { post_call("observation.policy_denied") } ],
      [ "explicit error", 200, "complete", 1, 1, -> { post_call("observation.explicit_error") } ],
      [ "host failure", 200, "complete", 1, 1, -> { post_call("observation.host_failure") } ],
      [ "success", 200, "complete", 1, 1, -> { post_call("observation.success") } ]
    ]

    cases.each do |label, status, outcome, request_count, invocation_count, action|
      events = capture_events { action.call }
      request_events = events.select { |event| event.name == "request.hitch_mcp" }

      assert_equal status, response.status, label
      assert_equal request_count, request_events.length, label
      assert_equal invocation_count, events.count { |event| event.name == "invocation.hitch_mcp" }, label
      assert_equal outcome, request_events.fetch(0).payload.fetch(:outcome), label if outcome
    end
  end

  test "exact structural payloads correlate without raw identities or request data" do
    request_body = nil
    events = capture_events do
      request_body = post_call(
        "observation.success",
        arguments: { "message" => "argument-canary" }
      )
    end
    assert_response :ok

    request_event = event_payload(events, "request.hitch_mcp")
    invocation_event = event_payload(events, "invocation.hitch_mcp")
    assert_equal REQUEST_EVENT_KEYS, request_event.keys
    assert_equal INVOCATION_EVENT_KEYS, invocation_event.keys
    assert_equal 1, request_event.fetch(:schema_version)
    assert_match(/\A[0-9a-f]{32}\z/, request_event.fetch(:request_id))
    assert_equal "tools/call", request_event.fetch(:method)
    assert_equal "observation.success", request_event.fetch(:tool_name)
    assert_equal "User", request_event.fetch(:principal_type)
    assert_match(/\A[0-9a-f]{64}\z/, request_event.fetch(:principal_key))
    assert_match(/\A[0-9a-f]{64}\z/, request_event.fetch(:client_key))
    assert_equal 200, request_event.fetch(:http_status)
    assert_nil request_event.fetch(:protocol_code)
    assert_equal "complete", request_event.fetch(:outcome)
    assert_equal request_body.bytesize, request_event.fetch(:request_bytes)
    assert_equal response.body.bytesize, request_event.fetch(:response_bytes)
    assert_operator request_event.fetch(:duration_ms), :>=, 0

    assert_equal request_event.fetch(:request_id), invocation_event.fetch(:request_id)
    assert_equal "observation.success", invocation_event.fetch(:tool_name)
    assert_equal "available", invocation_event.fetch(:availability)
    assert_equal "allowed", invocation_event.fetch(:argument_policy)
    assert_equal true, invocation_event.fetch(:executed)
    assert_equal "success", invocation_event.fetch(:result_category)
    assert_operator invocation_event.fetch(:duration_ms), :>=, 0
    assert_payload_strings_frozen(request_event)
    assert_payload_strings_frozen(invocation_event)

    raw_payload = JSON.generate(events.map(&:payload))
    refute_includes raw_payload, @token
    refute_includes raw_payload, @user.email
    refute_includes raw_payload, @client_id
    refute_includes raw_payload, "argument-canary"
  end

  test "identity HMACs survive token rotation and separate principals and clients" do
    first = request_payload_for(token: @token)
    rotated = request_payload_for(token: mint_token(@user, client_id: @client_id))
    other_client = request_payload_for(token: mint_token(@user, client_id: "observation-other-client"))
    other_user = User.create!(email: "observation-other@example.test")
    other_principal = request_payload_for(token: mint_token(other_user, client_id: @client_id))

    assert_equal first.fetch(:principal_key), rotated.fetch(:principal_key)
    assert_equal first.fetch(:client_key), rotated.fetch(:client_key)
    assert_equal first.fetch(:principal_key), other_client.fetch(:principal_key)
    refute_equal first.fetch(:client_key), other_client.fetch(:client_key)
    refute_equal first.fetch(:principal_key), other_principal.fetch(:principal_key)
    assert_equal first.fetch(:client_key), other_principal.fetch(:client_key)
    assert_equal 4, [ first, rotated, other_client, other_principal ].map { |payload| payload.fetch(:request_id) }.uniq.length
  end

  test "invocation event records policy execution and result categories only" do
    expected = {
      "observation.policy_denied" => [ "denied", false, "generic_error" ],
      "observation.policy_failure" => [ "failed", false, "generic_error" ],
      "observation.host_failure" => [ "allowed", true, "generic_error" ],
      "observation.explicit_error" => [ "allowed", true, "explicit_error" ],
      "observation.success" => [ "allowed", true, "success" ]
    }

    expected.each do |tool_name, values|
      events = capture_events { post_call(tool_name) }
      payload = event_payload(events, "invocation.hitch_mcp")

      assert_equal tool_name, payload.fetch(:tool_name)
      assert_equal values, payload.values_at(:argument_policy, :executed, :result_category)
      assert_equal INVOCATION_EVENT_KEYS, payload.keys
    end
  end

  test "sensitive canaries and subscriber failure are isolated" do
    reporter = ErrorReporter.new
    hostile_subscriber = lambda do |_event|
      raise "subscriber-secret argument-canary token-canary result-canary"
    end

    stub_class_method(Rails, :error, -> { reporter }) do
      ActiveSupport::Notifications.subscribed(
        hostile_subscriber,
        /\A(?:request|invocation)\.hitch_mcp\z/
      ) do
        post_call(
          "observation.success",
          token: @token,
          arguments: { "message" => "argument-canary token-canary result-canary" }
        )
      end
    end

    assert_response :ok
    assert_equal "observation-ok", JSON.parse(response.body).dig("result", "content", 0, "text")
    assert_equal 2, reporter.reports.length
    reporter.reports.each do |report|
      error = report.fetch(:error)
      options = report.fetch(:options)
      assert_equal "Hitch MCP observation delivery failed", error.message
      assert_nil error.cause
      assert_equal true, options.fetch(:handled)
      assert_equal :error, options.fetch(:severity)
      assert_equal "hitch.mcp.observation", options.fetch(:source)
      assert_equal %i[hitch_mcp_category hitch_mcp_event], options.fetch(:context).keys
      assert_includes %w[request.hitch_mcp invocation.hitch_mcp],
        options.dig(:context, :hitch_mcp_event)
    end

    public_bytes = response.body + reporter.reports.inspect
    refute_includes public_bytes, "subscriber-secret"
    refute_includes public_bytes, "argument-canary"
    refute_includes public_bytes, "token-canary"
    refute_includes public_bytes, "result-canary"
  end

  test "unexpected endpoint failures report only a synthetic category and safe request id" do
    reporter = ErrorReporter.new

    stub_class_method(Rails, :error, -> { reporter }) do
      stub_class_method(
        Hitch::AccessToken,
        :find_by_token,
        ->(*) { raise NameError, "authentication-secret" }
      ) do
        post_call("observation.success")
      end
      assert_response :service_unavailable

      post_call("observation.success", admission: "raise")
      assert_response :service_unavailable

      client_request_id = "eyJhbGciOiJIUzI1NiJ9.secret.signature"
      post_scope_failure(request_id: client_request_id)
      assert_response :ok
      assert_equal(-32_603, JSON.parse(response.body).dig("error", "code"))
      assert_equal client_request_id, JSON.parse(response.body).fetch("id")
    end

    assert_equal 3, reporter.reports.length
    expected = [
      [ "authentication", %i[hitch_mcp_category hitch_mcp_request_id] ],
      [ "request_admission", %i[hitch_mcp_category hitch_mcp_request_id] ],
      [ "dispatch", %i[hitch_mcp_category hitch_mcp_request_id] ]
    ]
    reporter.reports.zip(expected).each do |report, (category, context_keys)|
      error = report.fetch(:error)
      options = report.fetch(:options)
      context = options.fetch(:context)

      assert_equal "Hitch MCP endpoint failed", error.message
      assert_nil error.cause
      assert_equal true, options.fetch(:handled)
      assert_equal :error, options.fetch(:severity)
      assert_equal "hitch.mcp.endpoint", options.fetch(:source)
      assert_equal context_keys, context.keys
      assert_equal category, context.fetch(:hitch_mcp_category)
    end
    assert_match(/\A[0-9a-f]{32}\z/,
      reporter.reports.last.dig(:options, :context, :hitch_mcp_request_id))

    public_bytes = response.body + reporter.reports.inspect
    refute_includes public_bytes, "authentication-secret"
    refute_includes public_bytes, "wire-admission-secret"
    refute_includes public_bytes, "scope-failure-canary"
    refute_includes public_bytes, @token
    refute_includes public_bytes, @user.email
    refute_includes public_bytes, @client_id
    refute_includes reporter.reports.inspect, "eyJhbGciOiJIUzI1NiJ9.secret.signature"
  end

  test "a missing polymorphic principal remains an expected invalid credential" do
    Hitch::AccessToken.find_by_token(@token).update_column(:principal_type, "MissingPrincipal")
    reporter = ErrorReporter.new

    stub_class_method(Rails, :error, -> { reporter }) do
      post_call("observation.success")
    end

    assert_response :unauthorized
    assert_empty reporter.reports
  end

  test "endpoint reporting failure cannot change the fail-closed response" do
    failing_reporter = Object.new
    failing_reporter.define_singleton_method(:report) do |*|
      raise "reporter-secret"
    end

    stub_class_method(Rails, :error, -> { failing_reporter }) do
      post_call("observation.success", admission: "raise")
    end

    assert_response :service_unavailable
    assert_empty response.body
  end

  test "endpoint reporting context is fixed frozen and correlation-only" do
    internal = Hitch::MCP.const_get(:Internal, false)
    endpoint_reporter = internal.const_get(:EndpointErrorReporter, false)
    observation = internal.const_get(:Observation, false)

    {
      authentication: "authentication",
      request_admission: "request_admission",
      dispatch: "dispatch"
    }.each do |category, expected|
      stub_class_method(observation, :current_request_id, -> { nil }) do
        context = endpoint_reporter.__send__(:reporting_context, category)
        assert_equal({ hitch_mcp_category: expected }, context)
        assert_predicate context, :frozen?
      end
    end

    request_id = "a" * 32
    stub_class_method(observation, :current_request_id, -> { request_id }) do
      context = endpoint_reporter.__send__(:reporting_context, :dispatch)
      assert_equal %i[hitch_mcp_category hitch_mcp_request_id], context.keys
      assert_equal request_id, context.fetch(:hitch_mcp_request_id)
      assert_not_same request_id, context.fetch(:hitch_mcp_request_id)
      assert_predicate context.fetch(:hitch_mcp_request_id), :frozen?
      assert_predicate context, :frozen?
    end
    assert_raises(KeyError) { endpoint_reporter.__send__(:reporting_context, :unknown) }
  end

  test "correlation ids accept only copied frozen server-generated shape" do
    observation = Hitch::MCP.const_get(:Internal, false).const_get(:Observation, false)
    request_id = "0123456789abcdef" * 2
    copied = observation.__send__(:correlation_id, request_id)

    assert_equal request_id, copied
    assert_not_same request_id, copied
    assert_predicate copied, :frozen?
    string_subclass = Class.new(String).new("a" * 32)
    [ nil, Object.new, string_subclass, "", "a" * 31, "a" * 33, "A" * 32,
      "eyJhbGciOiJIUzI1NiJ9.secret.signature" ].each do |value|
      assert_nil observation.__send__(:correlation_id, value)
    end
  end

  test "publisher detaches and restores request state on success absence and subscriber failure" do
    observation = Hitch::MCP.const_get(:Internal, false).const_get(:Observation, false)
    current_key = observation.const_get(:CURRENT_REQUEST_KEY, false)
    execution_state = ActiveSupport::IsolatedExecutionState
    previous = Object.new
    payload = { schema_version: 1, request_id: "direct-observation" }.freeze
    event_name = "direct.hitch_mcp"
    observed = []
    subscription = ActiveSupport::Notifications.subscribe(event_name) do |event|
      observed << [ execution_state.key?(current_key), event.name, event.payload ]
      execution_state[current_key] = Object.new
    end

    execution_state[current_key] = previous
    assert_nil observation.__send__(:publish, event_name, payload)
    assert_equal [ [ false, event_name, payload ] ], observed
    assert_same previous, execution_state[current_key]

    execution_state.delete(current_key)
    assert_nil observation.__send__(:publish, event_name, payload)
    assert_equal false, execution_state.key?(current_key)
    assert_equal 2, observed.length

    reports = []
    failing_event = "direct-failure.hitch_mcp"
    failing_subscription = ActiveSupport::Notifications.subscribe(failing_event) do
      raise SystemStackError, "direct-subscriber-canary"
    end
    execution_state[current_key] = previous
    stub_class_method(observation, :report_failure, ->(*arguments) { reports << arguments }) do
      assert_nil observation.__send__(:publish, failing_event, payload)
    end
    assert_equal [ [ failing_event, "subscriber" ] ], reports
    assert_same previous, execution_state[current_key]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    ActiveSupport::Notifications.unsubscribe(failing_subscription) if failing_subscription
    execution_state&.delete(current_key) if current_key
  end

  private

  def configure_runtime
    Hitch.configure do |configuration|
      configuration.resource_uri = RESOURCE
      configuration.allowed_hosts = []
      configuration.allowed_origins = [ "https://allowed.example" ]
      configuration.supported_scopes = %w[mcp admin]
      configuration.mcp.registry = "HitchMcpObservationFixtures::Registry"
      configuration.mcp.server_info = ->(_context) { { name: "hitch-observation", version: "0.2.0" } }
      configuration.mcp.scope_resolver = ->(principal:, access_token:, request:) { principal }
      configuration.mcp.request_limit = { to: 1_000, within: 60 }
      configuration.mcp.rate_limit_store = ActiveSupport::Cache::MemoryStore.new
      configuration.mcp.max_request_bytes = 8_192
    end
    Hitch.configuration.validate!
    Hitch.configuration.mcp.__send__(
      :prepare_registry!,
      supported_scopes: Hitch.configuration.supported_scopes
    )
  end

  def capture_events
    events = []
    subscriber = ->(event) { events << event }
    ActiveSupport::Notifications.subscribed(
      subscriber,
      /\A(?:request|invocation)\.hitch_mcp\z/
    ) { yield }
    events
  end

  def event_payload(events, name)
    matching = events.select { |event| event.name == name }
    assert_equal 1, matching.length, name
    matching.fetch(0).payload
  end

  def request_payload_for(token:)
    events = capture_events { post_call("observation.success", token:) }
    event_payload(events, "request.hitch_mcp")
  end

  def post_call(
    name,
    token: @token,
    arguments: { "message" => "hello" },
    host: "dummy.test",
    origin: nil,
    admission: nil,
    content_type: "application/json",
    accept: "application/json, text/event-stream"
  )
    post_request(
      method: "tools/call",
      name:,
      arguments:,
      token:,
      host:,
      origin:,
      admission:,
      content_type:,
      accept:
    )
  end

  def post_request(
    method:,
    request_id: SecureRandom.hex(4),
    name: nil,
    arguments: {},
    token: @token,
    host: "dummy.test",
    origin: nil,
    admission: nil,
    content_type: "application/json",
    accept: "application/json, text/event-stream",
    protocol_version: PROTOCOL_VERSION,
    header_method: method
  )
    params = {
      "_meta" => {
        "io.modelcontextprotocol/protocolVersion" => protocol_version,
        "io.modelcontextprotocol/clientCapabilities" => {}
      }
    }
    if method == "tools/call"
      params["name"] = name
      params["arguments"] = arguments
    end
    body = JSON.generate(jsonrpc: "2.0", id: request_id, method:, params:)
    post_raw(
      body,
      method: header_method,
      name:,
      token:,
      host:,
      origin:,
      admission:,
      content_type:,
      accept:,
      protocol_version:
    )
    body
  end

  def post_raw(
    body,
    method:,
    name: nil,
    token: @token,
    host: "dummy.test",
    origin: nil,
    admission: nil,
    content_type: "application/json",
    accept: "application/json, text/event-stream",
    protocol_version: PROTOCOL_VERSION
  )
    headers = request_headers(
      method:,
      name:,
      token:,
      host:,
      origin:,
      admission:,
      content_type:,
      accept:,
      protocol_version:
    )
    post "/mcp", params: body, headers:
  end

  def get_mcp
    get "/mcp", headers: { "Host" => "dummy.test" }
  end

  def options_mcp
    process :options, "/mcp", headers: {
      "Host" => "dummy.test",
      "Origin" => "https://allowed.example",
      "Access-Control-Request-Method" => "POST",
      "Access-Control-Request-Headers" =>
        "Content-Type, Authorization, MCP-Protocol-Version, Mcp-Method, Mcp-Name"
    }
  end

  def request_headers(method:, name:, token:, host:, origin:, admission:, content_type:, accept:, protocol_version:)
    {
      "Host" => host,
      "Authorization" => ("Bearer #{token}" if token),
      "Content-Type" => content_type,
      "Accept" => accept,
      "MCP-Protocol-Version" => protocol_version,
      "Mcp-Method" => method,
      "Mcp-Name" => name,
      "Origin" => origin,
      "X-Hitch-Wire-Admission" => admission
    }.compact
  end

  def post_scope_failure(request_id: SecureRandom.hex(4))
    original = Hitch.configuration.mcp.scope_resolver
    Hitch.configuration.mcp.scope_resolver = ->(**) { raise "scope-failure-canary" }
    post_request(method: "tools/call", name: "observation.success", request_id:)
  ensure
    Hitch.configuration.mcp.scope_resolver = original
  end

  def mint_token(principal, client_id:)
    verifier = SecureRandom.urlsafe_base64(64)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    authorization = Hitch::AccessToken.create_authorization!(
      principal:,
      client_id:,
      client_name: "Observation Client",
      code_challenge: challenge,
      code_challenge_method: "S256",
      scopes: "mcp",
      resource_uri: RESOURCE
    )
    exchange_authorization_code(authorization, verifier:)
  end

  def assert_payload_strings_frozen(payload)
    payload.each_value do |value|
      assert_predicate value, :frozen? if value.is_a?(String)
    end
  end
end
