# frozen_string_literal: true

require "test_helper"
require "active_support/notifications"
require "base64"
require "digest"
require "json"
require "securerandom"
require "yaml"

module HitchMcpToolAuthorizationLatticeFixtures
  INPUT_SCHEMA = {
    type: "object",
    properties: { message: { type: "string" } },
    required: [ "message" ],
    additionalProperties: false
  }.freeze
  SAFE_ERROR_TEXT = "Safe retry guidance"

  class RuntimeState
    COUNTERS = %i[availability policy host].freeze

    def initialize
      @mutex = Mutex.new
      reset!
    end

    def configure!(values)
      @mutex.synchronize do
        @values = values.dup.freeze
        @counts = COUNTERS.index_with(0).freeze
      end
    end

    def fetch(name)
      @mutex.synchronize { @values.fetch(name.to_s) }
    end

    def increment!(name)
      @mutex.synchronize do
        @counts = @counts.merge(name => @counts.fetch(name) + 1).freeze
      end
    end

    def snapshot
      @mutex.synchronize { @counts.dup.freeze }
    end

    def reset!
      @mutex.synchronize do
        @values = {}.freeze
        @counts = COUNTERS.index_with(0).freeze
      end
    end
  end

  STATE = RuntimeState.new

  class Target < Hitch::MCP::Tool
    tool_name "lattice.target"
    description "Exercise every terminal authorization path"
    input_schema INPUT_SCHEMA

    class << self
      def available_to?(_context)
        STATE.increment!(:availability)
        STATE.fetch("tool_availability") == "available"
      end

      def authorize!(_context, arguments:)
        STATE.increment!(:policy)
        return if STATE.fetch("argument_policy") == "allow"

        raise Hitch::MCP::Forbidden, "lattice-policy-secret"
      end

      def perform(_context, arguments:)
        STATE.increment!(:host)
        case STATE.fetch("host_outcome")
        when "success"
          Hitch::MCP::Result.text("lattice-ok")
        when "safe_error"
          Hitch::MCP::Result.error(SAFE_ERROR_TEXT)
        when "raises"
          raise "lattice-host-secret"
        else
          raise "host outcome was reached outside the lattice contract"
        end
      end
    end
  end

  class Registry < Hitch::MCP::Registry
    register Target, scopes: %w[mcp invoke]
  end
end

class MCPToolAuthorizationLatticeTest < ActionDispatch::IntegrationTest
  ACTIVATION_CONSTANT = "Hitch::MCP::Tool"
  RUNTIME_TEST_NAMES = %w[
    test_exhaustive_terminal_paths
    test_expired_and_revoked_concrete_variants
    test_event_and_host_work_counts
  ].freeze
  RESOURCE = "https://dummy.test/mcp"
  PROTOCOL_VERSION = "2026-07-28"
  SCENARIO_PATH = Rails.root.join("../lattice/mcp_tool_authorization_scenarios.json").expand_path
  ORACLE_PATH = Rails.root.join("../contracts/mcp_tool_authorization_oracles.yml").expand_path
  SCENARIOS = JSON.parse(SCENARIO_PATH.read).fetch("scenarios").freeze
  ORACLES = YAML.safe_load_file(ORACLE_PATH, permitted_classes: [], aliases: false)
    .fetch("rows").index_by { |row| row.fetch("id") }.freeze
  PHASE_COUNTS = {
    1 => [ 1, 1, 1, 1, 1, 1, 1 ],
    2 => [ 0, 0, 0, 0, 0, 0, 0 ],
    3 => [ 0, 0, 0, 0, 0, 0, 0 ],
    4 => [ 0, 0, 0, 0, 0, 0, 0 ],
    5 => [ 0, 0, 0, 0, 0, 0, 0 ],
    6 => [ 1, 1, 1, 1, 0, 0, 0 ],
    7 => [ 1, 1, 1, 1, 1, 0, 0 ],
    8 => [ 1, 1, 1, 0, 1, 0, 0 ],
    9 => [ 1, 1, 1, 1, 1, 0, 0 ],
    10 => [ 1, 1, 1, 1, 1, 1, 0 ],
    11 => [ 1, 1, 1, 1, 1, 1, 1 ],
    12 => [ 1, 1, 1, 1, 1, 1, 1 ]
  }.freeze
  INVOCATION_CATEGORIES = {
    1 => [ "allowed", true, "success" ],
    10 => [ "denied", false, "generic_error" ],
    11 => [ "allowed", true, "explicit_error" ],
    12 => [ "allowed", true, "generic_error" ]
  }.freeze
  REQUEST_OUTCOMES = {
    1 => "complete",
    2 => "unauthorized",
    3 => "unauthorized",
    4 => "unauthorized",
    5 => "rate_limited",
    6 => "invalid_params",
    7 => "invalid_params",
    8 => "forbidden",
    9 => "complete",
    10 => "complete",
    11 => "complete",
    12 => "complete"
  }.freeze

  setup do
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    User.delete_all
    Hitch.reset_configuration!
    McpController.wire_slice_enabled = false
    configure_runtime
    @principal = User.create!(email: "lattice-principal@example.test")
    @tokens = {
      valid: mint_token(scopes: "mcp invoke", resource: RESOURCE),
      insufficient_scope: mint_token(scopes: "mcp", resource: RESOURCE),
      expired: mint_token(scopes: "mcp invoke", resource: RESOURCE),
      revoked: mint_token(scopes: "mcp invoke", resource: RESOURCE),
      wrong_audience: mint_token(scopes: "mcp invoke", resource: "https://elsewhere.test/mcp")
    }.freeze
    token_record(@tokens.fetch(:expired)).update!(expires_at: 1.minute.ago)
    token_record(@tokens.fetch(:revoked)).revoke!
  end

  teardown do
    HitchMcpToolAuthorizationLatticeFixtures::STATE.reset!
    McpController.wire_slice_enabled = false
    Hitch.reset_configuration!
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    User.delete_all
  end

  test "exhaustive terminal paths" do
    assert_equal (1..12).to_a, SCENARIOS.map { |scenario| scenario.fetch("id") }
    assert_equal SCENARIOS.map { |scenario| scenario.fetch("id") }, ORACLES.keys

    SCENARIOS.each do |scenario|
      result = execute_scenario(scenario)
      expected = ORACLES.fetch(scenario.fetch("id")).fetch("expected")

      assert_equal expected.fetch("http_status"), result.fetch(:http_status), scenario_label(scenario)
      if expected.fetch("protocol_code")
        assert_equal expected.fetch("protocol_code"), result.fetch(:protocol_code), scenario_label(scenario)
      else
        assert_nil result.fetch(:protocol_code), scenario_label(scenario)
      end
      assert_equal expected.fetch("result"), result.fetch(:result), scenario_label(scenario)
      refute_includes result.fetch(:response_body), "lattice-policy-secret", scenario_label(scenario)
      refute_includes result.fetch(:response_body), "lattice-host-secret", scenario_label(scenario)
    end
  end

  test "expired and revoked concrete variants" do
    scenario = SCENARIOS.find { |candidate| candidate.fetch("id") == 3 }
    expected = ORACLES.fetch(3).fetch("expected")
    variants = %i[expired revoked].to_h do |variant|
      result = execute_scenario(scenario, token_variant: variant)
      assert_equal expected.fetch("http_status"), result.fetch(:http_status), variant
      assert_equal expected.fetch("result"), result.fetch(:result), variant
      assert_equal expected.fetch("request_events"), result.fetch(:request_events), variant
      assert_equal expected.fetch("invocation_events"), result.fetch(:invocation_events), variant
      assert_equal expected.fetch("host_calls"), result.fetch(:host_calls), variant
      [ variant, result.slice(:http_status, :protocol_code, :result, :request_events, :invocation_events, :host_calls) ]
    end

    assert_equal variants.fetch(:expired), variants.fetch(:revoked)
  end

  test "event and host work counts" do
    SCENARIOS.each do |scenario|
      id = scenario.fetch("id")
      result = execute_scenario(scenario)
      expected = ORACLES.fetch(id).fetch("expected")

      assert_equal expected.fetch("request_events"), result.fetch(:request_events), scenario_label(scenario)
      assert_equal expected.fetch("invocation_events"), result.fetch(:invocation_events), scenario_label(scenario)
      assert_equal expected.fetch("host_calls"), result.fetch(:host_calls), scenario_label(scenario)
      assert_equal PHASE_COUNTS.fetch(id), result.fetch(:phase_counts), scenario_label(scenario)

      request_payload = result.fetch(:request_payload)
      assert_equal REQUEST_OUTCOMES.fetch(id), request_payload.fetch(:outcome), scenario_label(scenario)
      if id == 1 || id >= 5
        assert_match(/\A[0-9a-f]{64}\z/, request_payload.fetch(:principal_key), scenario_label(scenario))
        assert_match(/\A[0-9a-f]{64}\z/, request_payload.fetch(:client_key), scenario_label(scenario))
      else
        assert_nil request_payload.fetch(:principal_key), scenario_label(scenario)
        assert_nil request_payload.fetch(:client_key), scenario_label(scenario)
      end
      if id == 1 || id >= 8
        assert_equal "lattice.target", request_payload.fetch(:tool_name), scenario_label(scenario)
      else
        assert_nil request_payload.fetch(:tool_name), scenario_label(scenario)
      end

      invocation_payload = result.fetch(:invocation_payload)
      if INVOCATION_CATEGORIES.key?(id)
        assert_equal request_payload.fetch(:request_id), invocation_payload.fetch(:request_id), scenario_label(scenario)
        assert_equal INVOCATION_CATEGORIES.fetch(id),
          invocation_payload.values_at(:argument_policy, :executed, :result_category),
          scenario_label(scenario)
      else
        assert_nil invocation_payload, scenario_label(scenario)
      end
    end
  end

  private

  def configure_runtime
    Hitch.configure do |configuration|
      configuration.resource_uri = RESOURCE
      configuration.allowed_hosts = []
      configuration.allowed_origins = []
      configuration.supported_scopes = %w[mcp invoke]
      configuration.mcp.registry = "HitchMcpToolAuthorizationLatticeFixtures::Registry"
      configuration.mcp.server_info = ->(_context) { { name: "hitch-lattice", version: "0.2.0" } }
      configuration.mcp.scope_resolver = lambda do |principal:, access_token:, request:|
        @scope_calls += 1
        principal
      end
      configuration.mcp.request_limit = { to: 1_000, within: 60 }
      configuration.mcp.rate_limit_redis_url = nil
      configuration.mcp.max_request_bytes = 8_192
    end
    Hitch.configuration.validate!
    Hitch.configuration.mcp.__send__(
      :prepare_registry!,
      supported_scopes: Hitch.configuration.supported_scopes
    )
  end

  def execute_scenario(scenario, token_variant: nil)
    id = scenario.fetch("id")
    values = scenario.fetch("values")
    HitchMcpToolAuthorizationLatticeFixtures::STATE.configure!(values)
    McpController.reset_wire_metrics!
    @scope_calls = 0
    events = capture_events do
      post_lattice_call(
        id:,
        name: values.fetch("registration") == "unregistered" ? "lattice.missing" : "lattice.target",
        token: token_for(values, token_variant:),
        arguments: values.fetch("input_schema") == "invalid" ? { "message" => 7 } : { "message" => "hello" },
        admission: values.fetch("request_admission") == "reject" ? "reject" : nil
      )
    end
    parsed = response.body.present? ? JSON.parse(response.body) : {}
    request_event = events.select { |event| event.name == "request.hitch_mcp" }
    invocation_event = events.select { |event| event.name == "invocation.hitch_mcp" }
    state = HitchMcpToolAuthorizationLatticeFixtures::STATE.snapshot
    metrics = McpController.wire_metrics

    {
      http_status: response.status,
      protocol_code: parsed.dig("error", "code"),
      result: classify_result(parsed),
      response_body: response.body.to_s,
      request_events: request_event.length,
      invocation_events: invocation_event.length,
      host_calls: state.fetch(:host),
      phase_counts: [
        @scope_calls,
        metrics.fetch(:body_parses, 0),
        metrics.fetch(:registry, 0),
        metrics.fetch(:sdk, 0),
        state.fetch(:availability),
        state.fetch(:policy),
        state.fetch(:host)
      ],
      request_payload: request_event.fetch(0).payload,
      invocation_payload: invocation_event.fetch(0, nil)&.payload
    }.freeze
  end

  def post_lattice_call(id:, name:, token:, arguments:, admission:)
    body = {
      jsonrpc: "2.0",
      id: "lattice-#{id}",
      method: "tools/call",
      params: {
        "_meta" => {
          "io.modelcontextprotocol/protocolVersion" => PROTOCOL_VERSION,
          "io.modelcontextprotocol/clientCapabilities" => {}
        },
        "name" => name,
        "arguments" => arguments
      }
    }
    headers = {
      "Host" => "dummy.test",
      "Authorization" => ("Bearer #{token}" if token),
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream",
      "MCP-Protocol-Version" => PROTOCOL_VERSION,
      "Mcp-Method" => "tools/call",
      "Mcp-Name" => name,
      "X-Hitch-Wire-Admission" => admission
    }.compact
    post "/mcp", params: JSON.generate(body), headers:
  end

  def capture_events
    events = []
    ActiveSupport::Notifications.subscribed(
      ->(event) { events << event },
      /\A(?:request|invocation)\.hitch_mcp\z/
    ) { yield }
    events
  end

  def token_for(values, token_variant:)
    case values.fetch("token_state")
    when "missing" then nil
    when "expired_or_revoked" then @tokens.fetch(token_variant || :expired)
    when "wrong_audience" then @tokens.fetch(:wrong_audience)
    when "valid"
      values.fetch("oauth_scope") == "insufficient" ?
        @tokens.fetch(:insufficient_scope) : @tokens.fetch(:valid)
    else
      raise "unknown lattice token state"
    end
  end

  def classify_result(parsed)
    return "challenge" if response.status == 401
    return "retry_after" if response.status == 429
    return "step_up" if response.status == 403
    return "unknown_tool" if parsed.dig("error", "code") == -32_602

    result = parsed["result"]
    return "complete" unless result&.fetch("isError", false)
    return "explicit_safe_tool_error" if result.dig("content", 0, "text") ==
      HitchMcpToolAuthorizationLatticeFixtures::SAFE_ERROR_TEXT

    "generic_tool_error"
  end

  def mint_token(scopes:, resource:)
    verifier = SecureRandom.urlsafe_base64(64)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    authorization = Hitch::AccessToken.create_authorization!(
      principal: @principal,
      client_id: "lattice-client",
      client_name: "Lattice Client",
      code_challenge: challenge,
      code_challenge_method: "S256",
      scopes:,
      resource_uri: resource
    )
    exchange_authorization_code(authorization, verifier:)
  end

  def token_record(raw_token)
    Hitch::AccessToken.find_by!(token_digest: Digest::SHA256.hexdigest(raw_token))
  end

  def scenario_label(scenario)
    oracle = ORACLES.fetch(scenario.fetch("id"))
    "row #{scenario.fetch('id')} #{oracle.fetch('terminal')}"
  end
end
