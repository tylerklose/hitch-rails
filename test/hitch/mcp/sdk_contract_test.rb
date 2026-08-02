# frozen_string_literal: true

require "test_helper"
require "json"
require "mcp/server/transports/streamable_http_transport"

class Hitch::MCP::SDKContractTest < ActiveSupport::TestCase
  ACTIVATION_CONSTANT = "Hitch::MCP::SDKAdapter"
  RUNTIME_TEST_NAMES = %w[
    test_handle_requires_structural_symbol_keys
    test_selective_symbolization_preserves_untrusted_string_keys
    test_final_meta_accepts_absent_client_info
    test_tools_only_method_allowlist_precedes_sdk
    test_sdk_1_1_final_discover_normalizer_issue_389
    test_sdk_error_details_are_not_public
    test_sdk_output_validation_is_explicitly_enabled
    test_hostile_global_callbacks_receive_no_hitch_request_data
    test_sdk_callbacks_cannot_observe_arguments_or_body
    test_streamable_http_transport_is_not_used
    test_reserved_server_context_forms_fail_before_sdk_dispatch
    test_context_is_retrieved_from_hitch_context_wrapper
    test_tool_name_host_subset_documents_sdk_1_1_divergence
    test_fresh_server_per_request_isolates_principals
    test_sdk_lane_asserts_resolved_version
  ].freeze
  PROTOCOL_VERSION = "2026-07-28"
  SERVER_INFO = { "name" => "hitch-sdk-contract", "version" => "0.2.0" }.freeze
  REQUEST_META = {
    "io.modelcontextprotocol/protocolVersion" => PROTOCOL_VERSION,
    "io.modelcontextprotocol/clientCapabilities" => {}
  }.freeze

  class ToolDefinition
    attr_reader :name, :description, :input_schema, :output_schema

    def initialize(
      name: "echo",
      input_schema: { "type" => "object" },
      output_schema: nil,
      &implementation
    )
      @name = name
      @description = "SDK contract tool"
      @input_schema = input_schema
      @output_schema = output_schema
      @implementation = implementation || method(:default_implementation)
    end

    def call(arguments:, context:)
      @implementation.call(arguments:, context:)
    end

    private

    def default_implementation(arguments:, context:)
      ::MCP::Tool::Response.new(
        [ { type: "text", text: "ok" } ],
        structured_content: { "arguments" => arguments, "context" => context.to_s }
      )
    end
  end

  test "handle requires structural symbol keys" do
    raw_server = ::MCP::Server.new(name: "raw", version: "1", capabilities: { tools: {} })
    raw = raw_server.handle({
      "jsonrpc" => "2.0",
      "id" => "raw_request",
      "method" => "server/discover",
      "params" => {}
    })
    assert_equal(-32600, raw.dig(:error, :code))

    handled = []
    fake_server = Object.new
    fake_server.define_singleton_method(:handle) do |request|
      handled << request
      {
        jsonrpc: "2.0",
        id: request.fetch(:id),
        result: { supportedVersions: [], capabilities: {}, serverInfo: {} }
      }
    end

    stub_class_method(::MCP::Server, :new, ->(**) { fake_server }) do
      response = call_adapter(method: "server/discover")
      assert_equal "complete", response.dig(:result, :resultType)
    end

    request = handled.fetch(0)
    assert_equal %i[id jsonrpc method params], request.keys.sort
    assert_equal "server/discover", request.fetch(:method)
    assert_equal({}, request.fetch(:params))
    assert_deeply_frozen request
  end

  test "selective symbolization preserves untrusted string keys" do
    observed = nil
    tool = ToolDefinition.new do |arguments:, context:|
      observed = [ arguments, context ]
      ::MCP::Tool::Response.new([ { type: "text", text: "ok" } ])
    end
    params = {
      "name" => "echo",
      "arguments" => {
        "attacker_top_level" => {
          "nested-canary" => [ { "deeper canary" => "value" } ]
        }
      },
      "_meta" => REQUEST_META.merge("attacker-meta-key" => "meta-canary")
    }

    response = call_adapter(method: "tools/call", params:, tools: [ tool ], context: :authority)

    assert_nil response[:error]
    arguments, context = observed
    assert_equal :authority, context
    assert_equal "value", arguments.dig("attacker_top_level", "nested-canary", 0, "deeper canary")
    assert_all_hash_keys_are_strings arguments
    assert_deeply_frozen arguments
  end

  test "final meta accepts absent client info" do
    assert_raises(::MCP::Server::RequestHandlerError) do
      ::MCP::RequestEnvelope.parse!({ "_meta" => REQUEST_META })
    end

    response = call_adapter(
      method: "server/discover",
      params: { "_meta" => REQUEST_META }
    )

    assert_nil response[:error]
    assert_equal [ PROTOCOL_VERSION ], response.dig(:result, :supportedVersions)
  end

  test "tools only method allowlist precedes SDK" do
    stub_class_method(::MCP::Server, :new, ->(**) { flunk "SDK server must not be constructed" }) do
      response = call_adapter(method: "prompts/list")

      assert_equal(-32601, response.dig(:error, :code))
      assert_equal "Method not found", response.dig(:error, :message)
      assert_deeply_frozen response
    end
  end

  test "SDK 1.1 final discover normalizer issue 389" do
    raw_server = ::MCP::Server.new(
      **SERVER_INFO.transform_keys(&:to_sym),
      capabilities: { tools: {} },
      ttl_ms: 0,
      cache_scope: "private"
    )
    raw = raw_server.handle({
      jsonrpc: "2.0",
      id: "raw_discover",
      method: "server/discover",
      params: {}
    })
    assert_includes raw.dig(:result, :supportedVersions), "2025-03-26"
    assert raw.dig(:result, :serverInfo)
    assert_nil raw.dig(:result, :resultType)

    response = call_adapter(method: "server/discover")
    result = response.fetch(:result)

    assert_equal [ PROTOCOL_VERSION ], result.fetch(:supportedVersions)
    assert_equal({ tools: {} }, result.fetch(:capabilities))
    assert_nil result[:serverInfo]
    assert_equal SERVER_INFO,
      result.dig(:_meta, "io.modelcontextprotocol/serverInfo")
    assert_equal "complete", result.fetch(:resultType)
    assert_equal 0, result.fetch(:ttlMs)
    assert_equal "private", result.fetch(:cacheScope)
    assert_deeply_frozen response
  end

  test "SDK error details are not public" do
    secret_tool_name = "nonexistent-secret-tool"
    response = call_adapter(
      method: "tools/call",
      params: { "name" => secret_tool_name, "arguments" => {} }
    )

    assert_equal(-32602, response.dig(:error, :code))
    assert_equal "Invalid params", response.dig(:error, :message)
    refute_includes JSON.generate(response), secret_tool_name
    refute response.dig(:error).key?(:data)

    required_tool = ToolDefinition.new(
      input_schema: {
        "type" => "object",
        "required" => [ "secret_argument_name" ]
      }
    )
    tool_error = call_adapter(
      method: "tools/call",
      params: { "name" => "echo", "arguments" => {} },
      tools: [ required_tool ]
    )
    assert_equal true, tool_error.dig(:result, :isError)
    assert_equal "Tool execution failed", tool_error.dig(:result, :content, 0, :text)
    refute_includes JSON.generate(tool_error), "secret_argument_name"
  end

  test "SDK output validation is explicitly enabled" do
    invalid_tool = ToolDefinition.new(
      output_schema: {
        "type" => "object",
        "required" => [ "value" ],
        "properties" => { "value" => { "type" => "integer" } }
      }
    ) do |arguments:, context:|
      ::MCP::Tool::Response.new(
        [ { type: "text", text: "invalid" } ],
        structured_content: { "value" => "not-an-integer" }
      )
    end

    response = call_adapter(
      method: "tools/call",
      params: { "name" => "echo", "arguments" => {} },
      tools: [ invalid_tool ]
    )

    assert_equal(-32603, response.dig(:error, :code))
    assert_equal "Internal error", response.dig(:error, :message)
    refute response.fetch(:error).key?(:data)
    refute_includes JSON.generate(response), "not-an-integer"
  end

  test "hostile global callbacks receive no Hitch request data" do
    observed = []
    hostile = ::MCP::Configuration.new(
      exception_reporter: ->(*values) { observed << [ :exception, values ] },
      around_request: lambda { |data, &dispatch|
        observed << [ :around, data ]
        dispatch.call
      },
      instrumentation_callback: ->(data) { observed << [ :instrumentation, data ] }
    )
    raising_tool = ToolDefinition.new do |arguments:, context:|
      raise "host-exception-secret"
    end

    with_sdk_configuration(hostile) do
      response = call_adapter(
        method: "tools/call",
        params: {
          "name" => "echo",
          "arguments" => { "callback-secret" => "do-not-forward" }
        },
        tools: [ raising_tool ]
      )

      assert_equal(-32603, response.dig(:error, :code))
      assert_empty observed
      assert_same hostile, ::MCP.configuration
    end
  end

  test "SDK callbacks cannot observe arguments or body" do
    observed = []
    hostile = ::MCP::Configuration.new(
      exception_reporter: ->(*values) { observed << values },
      around_request: lambda { |data, &dispatch|
        observed << data
        dispatch.call
      },
      instrumentation_callback: ->(data) { observed << data }
    )

    with_sdk_configuration(hostile) do
      response = call_adapter(
        method: "tools/call",
        params: {
          "name" => "echo",
          "arguments" => { "raw-body-canary" => "argument-canary" }
        },
        tools: [ ToolDefinition.new ]
      )

      assert_nil response[:error]
      assert_empty observed
    end
  end

  test "Streamable HTTP transport is not used" do
    handle_calls = 0
    fake_server = Object.new
    fake_server.define_singleton_method(:handle) do |request|
      handle_calls += 1
      {
        jsonrpc: "2.0",
        id: request.fetch(:id),
        result: { supportedVersions: [], capabilities: {}, serverInfo: {} }
      }
    end
    fake_server.define_singleton_method(:handle_json) { flunk "handle_json must never be called" }

    stub_class_method(
      ::MCP::Server::Transports::StreamableHTTPTransport,
      :new,
      ->(*) { flunk "SDK HTTP transport must never be constructed" }
    ) do
      stub_class_method(::MCP::Server, :new, ->(**) { fake_server }) do
        response = call_adapter(method: "server/discover")
        assert_nil response[:error]
      end
    end

    assert_equal 1, handle_calls
  end

  test "reserved server context forms fail before SDK dispatch" do
    [ "server_context", :server_context ].each do |reserved_key|
      stub_class_method(::MCP::Server, :new, ->(**) { flunk "SDK server must not be constructed" }) do
        response = call_adapter(
          method: "tools/call",
          params: { "name" => "echo", "arguments" => { reserved_key => "attacker" } }
        )
        assert_equal(-32602, response.dig(:error, :code))
      end
    end

    observed = nil
    nested_tool = ToolDefinition.new do |arguments:, context:|
      observed = arguments
      ::MCP::Tool::Response.new([ { type: "text", text: "ok" } ])
    end
    response = call_adapter(
      method: "tools/call",
      params: {
        "name" => "echo",
        "arguments" => { "nested" => { "server_context" => "valid nested data" } }
      },
      tools: [ nested_tool ]
    )
    assert_nil response[:error]
    assert_equal "valid nested data", observed.dig("nested", "server_context")
  end

  test "context is retrieved from Hitch context wrapper" do
    context = { principal_id: "principal-42" }.freeze
    received_context = nil
    server_contexts = []
    original_new = ::MCP::Server.method(:new)
    tool = ToolDefinition.new do |arguments:, context:|
      received_context = context
      ::MCP::Tool::Response.new([ { type: "text", text: "ok" } ])
    end

    stub_class_method(::MCP::Server, :new, lambda { |**arguments|
      server_contexts << arguments.fetch(:server_context)
      original_new.call(**arguments)
    }) do
      response = call_adapter(
        method: "tools/call",
        params: {
          "name" => "echo",
          "arguments" => {},
          "_meta" => REQUEST_META.merge("attacker-meta" => "must-not-merge")
        },
        tools: [ tool ],
        context:
      )
      assert_nil response[:error]
    end

    assert_same context, received_context
    assert_equal [ { hitch_context: context } ], server_contexts
    assert_deeply_frozen server_contexts.fetch(0)
  end

  test "tool name host subset documents SDK 1.1 divergence" do
    sdk_only_name = "a" * 65
    assert ::MCP::Tool.define(name: sdk_only_name, input_schema: { type: "object" })

    error = assert_raises(ArgumentError) do
      call_adapter(method: "tools/list", tools: [ ToolDefinition.new(name: sdk_only_name) ])
    end
    assert_includes error.message, "1-64"

    response = call_adapter(
      method: "tools/list",
      tools: [ ToolDefinition.new(name: "a" * 64) ]
    )
    assert_equal "a" * 64, response.dig(:result, :tools, 0, :name)
  end

  test "fresh server per request isolates principals" do
    servers = []
    contexts = []
    original_new = ::MCP::Server.method(:new)
    tool = ToolDefinition.new do |arguments:, context:|
      contexts << context
      ::MCP::Tool::Response.new([ { type: "text", text: "ok" } ])
    end

    stub_class_method(::MCP::Server, :new, lambda { |**arguments|
      original_new.call(**arguments).tap { |server| servers << server }
    }) do
      %w[principal-a principal-b].each do |principal|
        response = call_adapter(
          method: "tools/call",
          params: { "name" => "echo", "arguments" => {} },
          tools: [ tool ],
          context: principal
        )
        assert_nil response[:error]
      end
    end

    assert_equal 2, servers.length
    refute_same servers.fetch(0), servers.fetch(1)
    assert_equal %w[principal-a principal-b], contexts
  end

  test "SDK lane asserts resolved version" do
    expected = ENV.fetch("HITCH_EXPECTED_MCP_VERSION", ::MCP::VERSION)
    assert_equal expected, ::MCP::VERSION
    assert_equal expected, Gem.loaded_specs.fetch("mcp").version.to_s

    lane = ENV["HITCH_SDK_LANE"]
    assert_includes %w[min latest], lane if lane
    assert_equal "1.1.0", expected if lane == "min"
  end

  private

  def adapter_class
    Hitch::MCP.const_get(:SDKAdapter, false)
  end

  def call_adapter(method:, params: {}, tools: [], context: Object.new, server_info: SERVER_INFO)
    adapter_class.call(
      verified_request: {
        "jsonrpc" => "2.0",
        "id" => "sdk_contract_request",
        "method" => method,
        "params" => params
      },
      tools:,
      context:,
      server_info:
    )
  end

  def with_sdk_configuration(configuration)
    existed = ::MCP.instance_variable_defined?(:@configuration)
    original = ::MCP.instance_variable_get(:@configuration)
    ::MCP.instance_variable_set(:@configuration, configuration)
    yield
  ensure
    if existed
      ::MCP.instance_variable_set(:@configuration, original)
    elsif ::MCP.instance_variable_defined?(:@configuration)
      ::MCP.remove_instance_variable(:@configuration)
    end
  end

  def assert_all_hash_keys_are_strings(value)
    case value
    when Hash
      assert value.keys.all? { |key| key.is_a?(String) }, "expected only String keys in #{value.inspect}"
      value.each_value { |child| assert_all_hash_keys_are_strings(child) }
    when Array
      value.each { |child| assert_all_hash_keys_are_strings(child) }
    end
  end

  def assert_deeply_frozen(value)
    assert_predicate value, :frozen?
    case value
    when Hash
      value.each do |key, child|
        assert_predicate key, :frozen? if key.respond_to?(:frozen?)
        assert_deeply_frozen child
      end
    when Array
      value.each { |child| assert_deeply_frozen(child) }
    end
  end
end
