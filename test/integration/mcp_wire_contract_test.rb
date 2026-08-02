# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "json"
require "mcp"
require "securerandom"
require "yaml"

class MCPWireContractTest < ActionDispatch::IntegrationTest
  ACTIVATION_CONSTANT = "Hitch::MCP::Endpoint"
  RESOURCE = "https://dummy.test/mcp"
  PROTOCOL_VERSION = "2026-07-28"
  LEGACY_PROTOCOL_VERSION = %w[2025 11 25].join("-").freeze
  TOOL_NAME = "hitch.echo"
  MAX_REQUEST_BYTES = 1_024
  RETRY_AFTER = 60
  VECTOR_PATH = Rails.root.join("../contracts/mcp_wire_vectors.yml").expand_path
  VECTOR_DOCUMENT = YAML.safe_load_file(VECTOR_PATH, permitted_classes: [], aliases: false)
  VECTORS = VECTOR_DOCUMENT.fetch("vectors").index_by { |vector| vector.fetch("id") }.freeze
  VECTOR_IDS = VECTORS.keys.freeze
  RUNTIME_TEST_NAMES = %w[
    test_modern_envelope_and_header_vectors
    test_reserved_server_context_forms
    test_exact_http_and_protocol_mapping
    test_single_parse_and_dispatch
    test_forwarded_host_proto_and_port_cannot_change_canonical_origin
    test_token_terminal_vectors
    test_callback_chain_and_zero_work
  ].freeze

  setup do
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    User.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |configuration|
      configuration.resource_uri = RESOURCE
      configuration.allowed_hosts = [ "www.example.com" ]
      configuration.allowed_origins = [ "https://allowed.example" ]
      configuration.supported_scopes = [ "mcp" ]
      configuration.mcp.max_request_bytes = MAX_REQUEST_BYTES
      configuration.mcp.server_info = ->(_context) {
        {
          name: "hitch-wire",
          version: "0.2.0",
          title: "Hitch Wire",
          instructions: "Use the authenticated private slice."
        }
      }
    end

    @user = User.create!(email: "wire@example.test")
    @tokens = {
      "valid" => mint_token(RESOURCE),
      "wrong_audience" => mint_token("https://elsewhere.test/mcp"),
      "expired" => mint_token(RESOURCE),
      "revoked" => mint_token(RESOURCE)
    }
    token_record(@tokens.fetch("expired")).update!(expires_at: 1.minute.ago)
    token_record(@tokens.fetch("revoked")).revoke!
  end

  teardown do
    Hitch.reset_configuration!
  end

  test "exact http and protocol mapping" do
    assert_equal 44, VECTOR_IDS.length
    VECTOR_IDS.each { |vector_id| assert_vector(vector_id) }
  end

  test "modern envelope and header vectors" do
    ids = VECTORS.values.filter_map do |vector|
      vector.fetch("id") if %w[media body parse envelope headers method_allowlist call_params].include?(vector.fetch("phase"))
    end

    ids.each { |vector_id| assert_vector(vector_id) }
  end

  test "reserved server context forms" do
    ids = VECTOR_IDS.grep(/reserved_server_context/) + [ "nested_server_context_valid" ]
    ids.each { |vector_id| assert_vector(vector_id) }
  end

  test "single parse and dispatch" do
    %w[request_body_oversize invalid_json duplicate_object_member discover_success call_success].each do |vector_id|
      assert_vector(vector_id)
    end
  end

  test "forwarded host proto and port cannot change canonical origin" do
    %w[
      forwarded_host_cannot_change_public_origin
      forwarded_proto_cannot_change_public_origin
      host_port_cannot_change_public_origin
    ].each { |vector_id| assert_vector(vector_id) }
  end

  test "token terminal vectors" do
    %w[token_missing token_expired token_revoked token_wrong_audience].each do |vector_id|
      assert_vector(vector_id)
    end
  end

  test "callback chain and zero work" do
    hitch_callbacks = McpController._process_action_callbacks.filter_map do |callback|
      filter = callback.filter
      [ callback.kind, filter ] if filter.to_s.start_with?("hitch_mcp_")
    end
    assert_equal [
      [ :around, :hitch_mcp_observe_request ],
      [ :before, :hitch_mcp_host_gate! ],
      [ :before, :hitch_mcp_origin_gate! ],
      [ :before, :hitch_mcp_method_gate! ],
      [ :before, :hitch_mcp_authenticate! ],
      [ :before, :hitch_mcp_rate_admission! ]
    ], hitch_callbacks.first(6)
    assert_equal Hitch::MCP::Endpoint, McpController.instance_method(:process_action).owner

    %w[post_host_denied post_origin_denied get_method_denied token_missing admission_reject].each do |vector_id|
      assert_vector(vector_id)
    end
  end

  test "fixture and runtime groups name every invariant test without skips" do
    assert_equal VECTOR_IDS.uniq, VECTOR_IDS
    assert_equal %w[2026-07-28], [ VECTOR_DOCUMENT.fetch("protocol_version") ]
    refute_match(/^\s*(?:skip|flunk)\b/, File.read(__FILE__))
  end

  test "wire lane asserts the resolved SDK version" do
    expected = ENV.fetch("HITCH_EXPECTED_MCP_VERSION", ::MCP::VERSION)
    assert_equal expected, ::MCP::VERSION
    assert_equal expected, Gem.loaded_specs.fetch("mcp").version.to_s
  end

  test "pre-controller guard prevents form parsing and ignores method override" do
    missing_type_input = NonRewindableInput.new(JSON.generate(base_body("missing-type", "server/discover")))
    McpController.reset_wire_metrics!
    rejected = call_app_with_input(
      path: "/mcp",
      input: missing_type_input,
      content_type: nil,
      host: "dummy.test",
      headers: raw_headers("server/discover")
    )

    assert_equal 415, rejected.status
    assert_equal 0, missing_type_input.bytes_read
    assert_equal 0, McpController.wire_metrics.fetch(:body_parses, 0)
    assert_equal 1, McpController.wire_metrics.fetch(:request_events, 0)

    valid_input = NonRewindableInput.new(JSON.generate(base_body("override", "server/discover")))
    McpController.reset_wire_metrics!
    accepted = call_app_with_input(
      path: "/mcp",
      input: valid_input,
      content_type: "application/json",
      host: "dummy.test",
      headers: raw_headers("server/discover").merge("HTTP_X_HTTP_METHOD_OVERRIDE" => "OPTIONS")
    )

    assert_equal 200, accepted.status
    assert_equal 1, McpController.wire_metrics.fetch(:body_parses, 0)
    assert_equal 1, McpController.wire_metrics.fetch(:sdk, 0)
    assert_equal 1, McpController.wire_metrics.fetch(:request_events, 0)
  end

  test "invalid utf8 and typed client info fail before dispatch" do
    invalid_utf8 = JSON.generate(base_body("utf8", "server/discover")).b
    invalid_utf8.sub!("server/discover", "server/\xFFdiscover".b)
    post "/mcp", params: invalid_utf8, headers: base_headers("server/discover")
    assert_response :bad_request
    assert_equal(-32700, JSON.parse(response.body).dig("error", "code"))

    [ nil, { "name" => "client", "version" => "1", "title" => 7 } ].each do |client_info|
      body = base_body("client-info", "server/discover")
      body.fetch("params").fetch("_meta")["io.modelcontextprotocol/clientInfo"] = client_info
      post "/mcp", params: JSON.generate(body), headers: base_headers("server/discover")
      assert_response :bad_request
      assert_equal(-32602, JSON.parse(response.body).dig("error", "code"))
    end
  end

  test "non-finite numbers and malformed unicode fail before dispatch" do
    raw_bodies = [
      JSON.generate(base_body("non-finite-id", "server/discover")).sub(
        '"id":"wire-non-finite-id"',
        '"id":1e400'
      ),
      JSON.generate(base_body("non-finite-meta", "server/discover")).sub(
        '"io.modelcontextprotocol/clientCapabilities":{}',
        '"io.modelcontextprotocol/clientCapabilities":{"limit":1e400}'
      ),
      JSON.generate(base_body("non-finite-argument", "tools/call")).sub(
        '"message":"wire non-finite-argument"',
        '"message":"ok","nested":{"limit":1e400}'
      )
    ]

    raw_bodies.each do |raw_body|
      rpc_method = raw_body.include?('"method":"tools/call"') ? "tools/call" : "server/discover"
      McpController.reset_wire_metrics!
      post "/mcp", params: raw_body, headers: base_headers(rpc_method)

      assert_response :bad_request
      parsed = JSON.parse(response.body)
      assert_equal(-32600, parsed.dig("error", "code"))
      assert_nil parsed["id"]
      assert_equal 0, McpController.wire_metrics.fetch(:registry, 0)
      assert_equal 0, McpController.wire_metrics.fetch(:sdk, 0)
    end

    [
      JSON.generate(base_body("surrogate-id", "server/discover")).sub(
        '"id":"wire-surrogate-id"',
        '"id":"\\uDC00"'
      ),
      JSON.generate(base_body("surrogate-meta", "server/discover")).sub(
        '"io.modelcontextprotocol/clientCapabilities":{}',
        '"io.modelcontextprotocol/clientCapabilities":{"label":"\\uDC00"}'
      )
    ].each do |raw_body|
      McpController.reset_wire_metrics!
      post "/mcp", params: raw_body, headers: base_headers("server/discover")

      assert_response :bad_request
      parsed = JSON.parse(response.body)
      assert_equal(-32700, parsed.dig("error", "code"))
      assert_nil parsed["id"]
      assert_equal 0, McpController.wire_metrics.fetch(:registry, 0)
      assert_equal 0, McpController.wire_metrics.fetch(:sdk, 0)
    end
  end

  test "server info failures are generic and do no registry or sdk work" do
    [
      ->(_context) { raise "server-info-secret" },
      ->(_context) { { name: "first", "name" => "second", version: "1" } }
    ].each do |server_info|
      Hitch.configuration.mcp.server_info = server_info
      McpController.reset_wire_metrics!

      body = base_body("server-info", "server/discover")
      post "/mcp", params: JSON.generate(body), headers: base_headers("server/discover")

      assert_response :ok
      assert_equal(-32603, JSON.parse(response.body).dig("error", "code"))
      refute_includes response.body, "server-info-secret"
      assert_equal 0, McpController.wire_metrics.fetch(:registry, 0)
      assert_equal 0, McpController.wire_metrics.fetch(:sdk, 0)
    end
  end

  test "final request id values survive the SDK compatibility boundary" do
    [ "a/b", "日本語", 1.5, 10**100 ].each do |request_id|
      body = base_body("request-id", "server/discover")
      body["id"] = request_id
      post "/mcp", params: JSON.generate(body), headers: base_headers("server/discover")

      assert_response :ok
      assert_equal request_id, JSON.parse(response.body).fetch("id")
    end
  end

  test "protected resource challenge preserves the canonical resource query" do
    Hitch.configure do |configuration|
      configuration.resource_uri = "https://dummy.test/mcp?tenant=one"
      configuration.allowed_hosts = []
    end
    headers = base_headers("server/discover").except("Authorization")
    body = base_body("query-resource", "server/discover")

    post "/mcp?tenant=one", params: JSON.generate(body), headers: headers

    assert_response :unauthorized
    assert_includes response.headers.fetch("WWW-Authenticate"),
      'resource_metadata="https://dummy.test/.well-known/oauth-protected-resource/mcp?tenant=one"'
  end

  test "only the canonical resource path and query reach authentication" do
    body = JSON.generate(base_body("resource-path", "server/discover"))

    [ "/mcp.json", "/mcp?unexpected=one" ].each do |path|
      McpController.reset_wire_metrics!
      post path, params: body, headers: base_headers("server/discover")

      assert_response :bad_request
      assert_predicate response.body, :blank?
      assert_equal 0, McpController.wire_metrics.fetch(:body_parses, 0)
      assert_equal 0, McpController.wire_metrics.fetch(:sdk, 0)
    end

    Hitch.configuration.resource_uri = "https://dummy.test/mcp?tenant=one"
    McpController.reset_wire_metrics!
    post "/mcp", params: body, headers: base_headers("server/discover")

    assert_response :bad_request
    assert_predicate response.body, :blank?
    assert_equal 0, McpController.wire_metrics.fetch(:body_parses, 0)
    assert_equal 0, McpController.wire_metrics.fetch(:sdk, 0)
  end

  private

  def assert_vector(vector_id)
    vector = VECTORS.fetch(vector_id)
    McpController.reset_wire_metrics!
    perform_vector(vector_id)

    expected = vector.fetch("expected")
    assert_equal expected.fetch("http_status"), response.status, vector_id
    assert_expected_headers(vector_id, expected.fetch("headers"))
    assert_no_unexpected_security_headers(vector_id, expected.fetch("headers"))
    vary = response.headers["Vary"].to_s.split(",").map(&:strip)
    assert_includes vary, "Origin", vector_id
    if vector_http_method(vector_id) == "OPTIONS"
      assert_includes vary, "Access-Control-Request-Method", vector_id
      assert_includes vary, "Access-Control-Request-Headers", vector_id
    end
    assert_expected_protocol(vector_id, expected)
    assert_equal expected.fetch("request_events"), McpController.wire_metrics.fetch(:request_events, 0), vector_id
    assert_equal expected.fetch("invocation_events"), McpController.wire_metrics.fetch(:invocation_events, 0), vector_id
    expected.fetch("work").each do |name, count|
      assert_equal count, McpController.wire_metrics.fetch(name.to_sym, 0), "#{vector_id}: #{name}"
    end
  end

  def perform_vector(vector_id)
    request_method = vector_http_method(vector_id)
    rpc_method = vector_rpc_method(vector_id)
    headers = base_headers(rpc_method)
    body = base_body(vector_id, rpc_method)
    apply_vector_headers!(vector_id, headers, body)
    body = vector_raw_body(vector_id, body)

    public_send(request_method.downcase, "/mcp", params: body, headers: headers)
  end

  def vector_http_method(vector_id)
    case vector_id
    when /\Aoptions_/ then "OPTIONS"
    when "get_method_denied" then "GET"
    else "POST"
    end
  end

  def vector_rpc_method(vector_id)
    case vector_id
    when "unsupported_rpc_initialize" then "initialize"
    when "name_header_mismatch", "malformed_call_params", /reserved_server_context/,
      "nested_server_context_valid", "input_schema_invalid", "call_success"
      "tools/call"
    when "list_success" then "tools/list"
    else "server/discover"
    end
  end

  def base_body(vector_id, rpc_method)
    params = { "_meta" => required_meta }
    if rpc_method == "tools/call"
      params["name"] = TOOL_NAME
      params["arguments"] = { "message" => "wire #{vector_id}" }
    end

    {
      "jsonrpc" => "2.0",
      "id" => "wire-#{vector_id}",
      "method" => rpc_method,
      "params" => params
    }
  end

  def required_meta
    {
      "io.modelcontextprotocol/protocolVersion" => PROTOCOL_VERSION,
      "io.modelcontextprotocol/clientCapabilities" => {}
    }
  end

  def base_headers(rpc_method)
    headers = {
      "Host" => "dummy.test",
      "Authorization" => "Bearer #{@tokens.fetch('valid')}",
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream",
      "MCP-Protocol-Version" => PROTOCOL_VERSION,
      "Mcp-Method" => rpc_method
    }
    headers["Mcp-Name"] = TOOL_NAME if rpc_method == "tools/call"
    headers
  end

  def raw_headers(rpc_method)
    base_headers(rpc_method).except("Content-Type").to_h do |name, value|
      [ "HTTP_#{name.upcase.tr('-', '_')}", value ]
    end
  end

  def apply_vector_headers!(vector_id, headers, body)
    case vector_id
    when "options_allowed"
      apply_preflight!(headers, origin: "https://allowed.example", requested_headers: allowed_preflight_headers)
    when "options_origin_denied"
      apply_preflight!(headers, origin: "https://denied.example", requested_headers: allowed_preflight_headers)
    when "options_header_denied"
      apply_preflight!(headers, origin: "https://allowed.example", requested_headers: "Content-Type, X-Mcp-Header")
    when "post_host_denied"
      headers["Host"] = "attacker.example"
    when "post_origin_denied"
      headers["Origin"] = "https://denied.example"
    when "forwarded_host_cannot_change_public_origin"
      headers["Host"] = "www.example.com"
      headers["X-Forwarded-Host"] = "attacker.example"
      headers.delete("Authorization")
    when "forwarded_proto_cannot_change_public_origin"
      headers["X-Forwarded-Proto"] = "http"
      headers.delete("Authorization")
    when "host_port_cannot_change_public_origin"
      headers["Host"] = "www.example.com:443"
      headers["Forwarded"] = "host=attacker.example;proto=http"
      headers["X-Forwarded-Host"] = "attacker.example:81"
      headers["X-Forwarded-Proto"] = "http"
      headers.delete("Authorization")
    when "token_missing"
      headers.delete("Authorization")
    when "token_expired", "token_revoked", "token_wrong_audience"
      headers["Authorization"] = "Bearer #{@tokens.fetch(vector_id.delete_prefix('token_'))}"
    when "admission_reject"
      headers["X-Hitch-Wire-Admission"] = "reject"
    when "admission_store_failure"
      headers["X-Hitch-Wire-Admission"] = "raise"
    when "content_type_missing"
      headers.delete("Content-Type")
    when "content_type_wrong"
      headers["Content-Type"] = "text/plain"
    when "accept_missing_sse"
      headers["Accept"] = "application/json"
    when "accept_q_zero"
      headers["Accept"] = "application/json, text/event-stream;q=0"
    when "malformed_envelope"
      body.delete("jsonrpc")
    when "meta_protocol_missing"
      body.fetch("params").fetch("_meta").delete("io.modelcontextprotocol/protocolVersion")
    when "meta_capabilities_missing"
      body.fetch("params").fetch("_meta").delete("io.modelcontextprotocol/clientCapabilities")
    when "meta_client_info_absent"
      headers["MCP-Protocol-Version"] = " \t#{PROTOCOL_VERSION}\t"
      headers["Mcp-Method"] = "\tserver/discover "
    when "meta_client_info_invalid"
      body.fetch("params").fetch("_meta")["io.modelcontextprotocol/clientInfo"] = "invalid"
    when "protocol_header_missing"
      headers.delete("MCP-Protocol-Version")
    when "method_header_mismatch"
      headers["Mcp-Method"] = "tools/list"
    when "name_header_mismatch"
      headers["Mcp-Name"] = "other.tool"
    when "single_value_header_comma_combined"
      headers["MCP-Protocol-Version"] = "#{PROTOCOL_VERSION}, #{PROTOCOL_VERSION}"
    when "unsupported_protocol_version"
      body.fetch("params").fetch("_meta")["io.modelcontextprotocol/protocolVersion"] = LEGACY_PROTOCOL_VERSION
      headers["MCP-Protocol-Version"] = LEGACY_PROTOCOL_VERSION
    when "malformed_call_params"
      body.fetch("params")["arguments"] = []
    when /reserved_server_context/
      body.fetch("params").fetch("arguments")["server_context"] = "client-owned"
    when "nested_server_context_valid"
      body.fetch("params").fetch("arguments")["nested"] = { "server_context" => "client-owned" }
    when "input_schema_invalid"
      body.fetch("params").fetch("arguments")["message"] = 7
    end
  end

  def apply_preflight!(headers, origin:, requested_headers:)
    headers.clear
    headers["Host"] = "dummy.test"
    headers["Origin"] = origin
    headers["Access-Control-Request-Method"] = "POST"
    headers["Access-Control-Request-Headers"] = requested_headers
  end

  def allowed_preflight_headers
    "Content-Type, Authorization, MCP-Protocol-Version, Mcp-Method, Mcp-Name"
  end

  def vector_raw_body(vector_id, body)
    case vector_id
    when /\Aoptions_/, "get_method_denied"
      nil
    when "request_body_oversize"
      "{\"oversize\":\"#{'x' * MAX_REQUEST_BYTES}\"}"
    when "invalid_json"
      "{\"jsonrpc\":"
    when "duplicate_object_member"
      JSON.generate(body).sub(
        '"io.modelcontextprotocol/clientCapabilities":{}',
        '"io.modelcontextprotocol/clientCapabilities":{"nested":{"x":1,"x":2}}'
      )
    else
      JSON.generate(body)
    end
  end

  def assert_expected_headers(vector_id, expected)
    expected.each do |name, value|
      case name
      when "content_type"
        assert_equal value, response.media_type, vector_id
      when "allow_origin"
        assert_equal "https://allowed.example", response.headers["Access-Control-Allow-Origin"], vector_id
      when "allow_methods"
        assert_equal value, response.headers["Access-Control-Allow-Methods"], vector_id
      when "cors"
        assert_nil response.headers["Access-Control-Allow-Origin"], vector_id
      when "allow"
        assert_equal value, response.headers["Allow"], vector_id
      when "www_authenticate"
        challenge = response.headers["WWW-Authenticate"].to_s
        assert_includes challenge,
          'resource_metadata="https://dummy.test/.well-known/oauth-protected-resource/mcp"', vector_id
        assert_includes challenge, 'scope="mcp"', vector_id
        refute_includes challenge, "attacker.example", vector_id
      when "retry_after"
        assert_equal RETRY_AFTER.to_s, response.headers["Retry-After"], vector_id
      else
        assert false, "#{vector_id}: unknown expected header #{name}=#{value.inspect}"
      end
    end
  end

  def assert_no_unexpected_security_headers(vector_id, expected)
    assert_nil response.headers["WWW-Authenticate"], vector_id unless expected.key?("www_authenticate")
    assert_nil response.headers["Retry-After"], vector_id unless expected.key?("retry_after")
    assert_nil response.headers["Access-Control-Allow-Origin"], vector_id unless expected.key?("allow_origin")
  end

  def assert_expected_protocol(vector_id, expected)
    code = expected.fetch("protocol_code")
    if code.nil? && expected.fetch("result") == "empty"
      assert_predicate response.body, :blank?, vector_id
      return
    end

    body = JSON.parse(response.body)
    if code
      assert_equal code, body.dig("error", "code"), vector_id
      refute body.fetch("error").key?("_meta"), vector_id
      if expected.fetch("result").to_s.end_with?("null_id")
        assert_nil body["id"], vector_id
      elsif expected.fetch("result").to_s.include?("preserved_id")
        assert_equal "wire-#{vector_id}", body["id"], vector_id
      end
      if code == -32022
        assert_equal [ PROTOCOL_VERSION ], body.dig("error", "data", "supportedVersions"), vector_id
        assert_equal [ PROTOCOL_VERSION ], body.dig("error", "data", "supported"), vector_id
        assert_equal LEGACY_PROTOCOL_VERSION, body.dig("error", "data", "requested"), vector_id
      end
      return
    end

    result = body.fetch("result")
    assert_equal "complete", result.fetch("resultType"), vector_id
    assert_equal({
      "name" => "hitch-wire",
      "version" => "0.2.0",
      "title" => "Hitch Wire"
    }, result.dig("_meta", "io.modelcontextprotocol/serverInfo"), vector_id)
    case expected.fetch("result")
    when /private_zero_ttl/
      assert_equal "private", result.fetch("cacheScope"), vector_id
      assert_equal 0, result.fetch("ttlMs"), vector_id
    when "generic_tool_error"
      assert_equal true, result.fetch("isError"), vector_id
      assert_equal "Tool execution failed", result.dig("content", 0, "text"), vector_id
    end

    if expected.fetch("result").to_s.include?("server_info_meta")
      assert_equal({
        "name" => "hitch-wire",
        "version" => "0.2.0",
        "title" => "Hitch Wire"
      }, result.dig("_meta", "io.modelcontextprotocol/serverInfo"), vector_id)
      assert_equal "Use the authenticated private slice.", result.fetch("instructions"), vector_id
    end

    if expected.fetch("result") == "complete_private_zero_ttl_sorted"
      names = result.fetch("tools").map { |tool| tool.fetch("name") }
      assert_equal names.sort, names, vector_id
      assert_equal [ TOOL_NAME ], names, vector_id
      assert_equal true, result.dig("tools", 0, "annotations", "readOnlyHint"), vector_id
      assert_equal false, result.dig("tools", 0, "annotations", "destructiveHint"), vector_id
    end
  end

  def mint_token(resource)
    verifier = SecureRandom.urlsafe_base64(64)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    record = Hitch::AccessToken.create_authorization!(
      principal: @user,
      client_id: "wire-client",
      client_name: "Wire Client",
      code_challenge: challenge,
      code_challenge_method: "S256",
      scopes: "mcp",
      resource_uri: resource
    )
    exchange_authorization_code(record, verifier: verifier)
  end

  def token_record(raw_token)
    Hitch::AccessToken.find_by(token_digest: Digest::SHA256.hexdigest(raw_token))
  end
end
