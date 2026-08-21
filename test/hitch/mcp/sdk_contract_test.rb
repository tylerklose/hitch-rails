# frozen_string_literal: true

require "test_helper"
require "json"
require "mcp"
require "mcp/server/transports/streamable_http_transport"

class Hitch::MCP::SDKContractTest < ActiveSupport::TestCase
  ACTIVATION_CONSTANT = "Hitch::MCP::Internal::SDKAdapter"
  RUNTIME_TEST_NAMES = %w[
    test_handle_requires_structural_symbol_keys
    test_selective_symbolization_preserves_untrusted_string_keys
    test_final_meta_accepts_absent_client_info
    test_tools_only_method_allowlist_precedes_sdk
    test_final_discover_shape_is_owned_by_hitch
    test_sdk_error_details_are_not_public
    test_hitch_owns_the_one_output_schema_validation
    test_hostile_global_callbacks_receive_no_hitch_request_data
    test_sdk_callbacks_cannot_observe_arguments_or_body
    test_streamable_http_transport_is_not_used
    test_reserved_server_context_forms_fail_before_sdk_dispatch
    test_context_is_retrieved_from_hitch_context_wrapper
    test_tool_name_host_subset_matches_sdk_grammar
    test_fresh_server_per_request_isolates_principals
    test_resolved_sdk_version_is_in_the_supported_window
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
      implementation = @implementation
      @tool_class = Class.new(Hitch::MCP::Tool)
      @tool_class.output_schema(output_schema) if output_schema
      @tool_class.define_singleton_method(:authorize!) do |_context, arguments:|
      end
      @tool_class.define_singleton_method(:perform) do |context, arguments:|
        implementation.call(arguments:, context:)
      end
    end

    def call(server_context:, **arguments)
      @tool_class.call(server_context:, **arguments)
    end

    private

    def default_implementation(arguments:, context:)
      Hitch::MCP::Result.text("ok")
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
      Hitch::MCP::Result.text("ok")
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
    # mcp 1.2 made clientInfo optional (spec PR modelcontextprotocol#3002);
    # Hitch additionally never lets _meta cross its boundary.
    assert ::MCP::RequestEnvelope.parse!({ "_meta" => REQUEST_META })

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

  test "final discover shape is owned by Hitch" do
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
    # The SDK's own raw shape is modern on the supported line; Hitch still
    # owns the final wire shape below rather than trusting it.
    assert_equal [ PROTOCOL_VERSION ], raw.dig(:result, :supportedVersions)

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

  test "hitch owns the one output schema validation" do
    # The SDK's validate_tool_call_results pass is off (pinned in the
    # configuration test below): ResultNormalizer validates every structured
    # result inside framework-owned Tool.call before the SDK sees it, so an
    # invalid structured result fails with the exact bytes it always had.
    output_schema = {
      "type" => "object",
      "required" => [ "value" ],
      "properties" => { "value" => { "type" => "integer" } }
    }
    invalid_tool = ToolDefinition.new(output_schema:) do |arguments:, context:|
      Hitch::MCP::Result.structured({ "value" => "not-an-integer" })
    end

    response = call_adapter(
      method: "tools/call",
      params: { "name" => "echo", "arguments" => {} },
      tools: [ invalid_tool ]
    )

    assert_nil response[:error]
    result = response.fetch(:result)
    assert_equal true, result.fetch(:isError)
    assert_equal [ { type: "text", text: "Tool execution failed" } ], result.fetch(:content)
    refute result.key?(:structuredContent)
    refute_includes JSON.generate(response), "not-an-integer"
  end

  test "explicit Result error is the only message preserving tool error" do
    public_message = "Safe retry guidance"
    tool = ToolDefinition.new do |arguments:, context:|
      Hitch::MCP::Result.error(public_message)
    end

    response = call_adapter(
      method: "tools/call",
      params: { "name" => "echo", "arguments" => {} },
      tools: [ tool ]
    )

    assert_nil response[:error]
    assert_equal true, response.dig(:result, :isError)
    assert_equal public_message, response.dig(:result, :content, 0, :text)
    refute response.fetch(:result).key?(:structuredContent)
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

      assert_equal true, response.dig(:result, :isError)
      assert_equal "Tool execution failed", response.dig(:result, :content, 0, :text)
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
    stub_class_method(::MCP::Server, :new, ->(**) { flunk "SDK server must not be constructed" }) do
      response = call_adapter(
        method: "tools/call",
        params: { "name" => "echo", "arguments" => { "server_context" => "attacker" } }
      )
      assert_equal(-32602, response.dig(:error, :code))
    end

    observed = nil
    nested_tool = ToolDefinition.new do |arguments:, context:|
      observed = arguments
      Hitch::MCP::Result.text("ok")
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

  # The adapter's input is VerifiedRequest's product — plain, string-keyed,
  # deep-frozen Hashes off JSON.parse — so the predicate is exact for that
  # contract; symbol or Hash-subclass forms cannot reach it. The wire-level
  # reserved_server_context_* vectors pin the production path end to end.
  test "reserved context predicate is exact for method shape and key" do
    assert_equal false, reserved_context_predicate(method: "server/discover", arguments: { "server_context" => true })
    assert_equal false, reserved_context_predicate(method: "tools/list", arguments: { "server_context" => true })
    [ nil, [], "value", {}, { "nested" => { "server_context" => true } } ].each do |arguments|
      assert_equal false, reserved_context_predicate(method: "tools/call", arguments:)
    end
    assert_equal true, reserved_context_predicate(method: "tools/call", arguments: { "server_context" => nil })
  end

  test "private SDK configuration installs every fixed validation and inert callback" do
    configuration = raw_internal_adapter(method: "server/discover", arguments: nil)
      .__send__(:sdk_configuration)

    # No pin is installed: mcp >= 1.2 refuses pinning a modern version, and
    # the pin only ever scoped the legacy initialize handshake, which Hitch
    # never serves. The unpinned default differs per SDK line and is unused.
    assert_equal false, configuration.protocol_version?
    assert_equal true, configuration.validate_tool_call_arguments
    # Explicitly false, not merely defaulted: Hitch's ResultNormalizer is the
    # one output-schema validation, and this survives an SDK default change.
    assert_equal false, configuration.validate_tool_call_results
    assert_equal true, configuration.exception_reporter?
    assert_equal true, configuration.around_request?
    assert_equal true, configuration.instrumentation_callback?
    assert_nil configuration.exception_reporter.call(RuntimeError.new("callback-canary"), { "secret" => true })
    calls = 0
    assert_equal :handled, configuration.around_request.call({ "secret" => true }) { calls += 1; :handled }
    assert_equal 1, calls
    assert_nil configuration.instrumentation_callback.call({ "secret" => true })

    captured = nil
    sentinel = Object.new
    stub_class_method(::MCP::Configuration, :new, lambda { |**keywords|
      captured = keywords
      sentinel
    }) do
      assert_same sentinel, raw_internal_adapter(method: "server/discover", arguments: nil)
        .__send__(:sdk_configuration)
    end
    assert_equal %i[
      around_request exception_reporter instrumentation_callback
      validate_tool_call_arguments validate_tool_call_results
    ], captured.keys.sort
    assert_equal true, captured.fetch(:validate_tool_call_arguments)
    assert_equal false, captured.fetch(:validate_tool_call_results)
    assert_nil captured.fetch(:exception_reporter).call(RuntimeError.new, {})
    assert_equal :handled, captured.fetch(:around_request).call({}) { :handled }
    assert_nil captured.fetch(:instrumentation_callback).call({})
  end

  test "context is retrieved from Hitch context wrapper" do
    context = Hitch::MCP::Context.new(
      principal: Object.new,
      access_token: Object.new,
      scope: nil,
      granted_scopes: [ "mcp" ],
      client_id: "sdk-client",
      resource: "https://sdk.test/mcp",
      request_id: "sdk-context",
      remote_ip: "198.51.100.42",
      user_agent: nil,
      protocol_version: PROTOCOL_VERSION,
      meta: REQUEST_META
    )
    received_context = nil
    server_contexts = []
    original_new = ::MCP::Server.method(:new)
    tool = ToolDefinition.new do |arguments:, context:|
      received_context = context
      Hitch::MCP::Result.text("ok")
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
    assert_equal 1, server_contexts.length
    server_context = server_contexts.fetch(0)
    assert_equal %i[hitch_context hitch_dispatch], server_context.keys.sort
    assert_same context, server_context.fetch(:hitch_context)
    assert_deeply_frozen server_context
  end

  test "tool name host subset matches SDK grammar" do
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

  test "adapter reuses a definition's prebuilt SDK tool wrapper" do
    definition = ToolDefinition.new
    sdk_tool = adapter_class.build_sdk_tool(
      name: definition.name,
      description: definition.description,
      input_schema: definition.input_schema
    )
    definition.define_singleton_method(:sdk_tool) { sdk_tool }

    captured_tools = nil
    original_new = ::MCP::Server.method(:new)
    stub_class_method(::MCP::Server, :new, lambda { |**arguments|
      captured_tools = arguments.fetch(:tools)
      original_new.call(**arguments)
    }) do
      2.times do
        response = call_adapter(
          method: "tools/call",
          params: { "name" => "echo", "arguments" => {} },
          tools: [ definition ]
        )
        assert_nil response[:error]
        assert_equal 1, captured_tools.length
        assert_same sdk_tool, captured_tools.fetch(0)
      end
    end
  end

  test "one memoized SDK tool serves concurrent requests without sharing context" do
    started = Queue.new
    release = Queue.new
    shared = ToolDefinition.new do |arguments:, context:|
      started << true
      release.pop
      # Echoing the principal into the result is the leak detector: a shared
      # or stale context would answer one request with the other's principal.
      Hitch::MCP::Result.text(context)
    end
    sdk_tool = adapter_class.build_sdk_tool(
      name: shared.name,
      description: shared.description,
      input_schema: shared.input_schema
    )
    shared.define_singleton_method(:sdk_tool) { sdk_tool }

    threads = %w[principal-a principal-b].map do |principal|
      Thread.new do
        call_adapter(
          method: "tools/call",
          params: { "name" => "echo", "arguments" => {} },
          tools: [ shared ],
          context: principal
        ).dig(:result, :content, 0, :text)
      end
    end
    # Both invocations sit inside the one shared wrapper before either
    # finishes, so the two requests demonstrably overlap in time. The pops
    # time out rather than hang so a broken build fails instead of stalling.
    overlapped = 2.times.map { !started.pop(timeout: 5).nil? }
    2.times { release << true }

    assert_equal [ true, true ], overlapped, "both requests must reach the shared wrapper concurrently"
    assert_equal %w[principal-a principal-b], threads.map(&:value)
  end

  test "fresh server per request isolates principals" do
    servers = []
    contexts = []
    original_new = ::MCP::Server.method(:new)
    tool = ToolDefinition.new do |arguments:, context:|
      contexts << context
      Hitch::MCP::Result.text("ok")
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

  test "resolved SDK version is in the supported window" do
    resolved = Gem.loaded_specs.fetch("mcp").version
    assert_equal ::MCP::VERSION, resolved.to_s
    assert Gem::Requirement.new(">= 1.2", "< 2").satisfied_by?(resolved)
  end

  test "verified request ids survive the SDK validation subset" do
    [ "a/b", "日本語", 1.5, 10**100 ].each do |request_id|
      response = call_adapter(
        method: "server/discover",
        params: { "_meta" => REQUEST_META },
        request_id: request_id
      )

      assert_nil response[:error]
      assert_equal request_id, response[:id]
    end
  end

  test "malformed SDK responses become a generic internal error" do
    [ nil, {}, { result: nil }, { error: "secret-sdk-error" }, { error: {} },
      { error: { code: "secret-sdk-code" } }, { result: {}, error: nil },
      { result: {}, error: false }, { result: {}, "result" => {} },
      { result: {}, error: { code: -32603, message: "secret-sdk-error" } } ].each do |sdk_response|
      fake_server = Object.new
      fake_server.define_singleton_method(:handle) { |_request| sdk_response }

      stub_class_method(::MCP::Server, :new, ->(**) { fake_server }) do
        response = call_adapter(method: "server/discover", request_id: "original-id")

        assert_equal "2.0", response.fetch(:jsonrpc)
        assert_equal "original-id", response.fetch(:id)
        assert_equal(-32603, response.dig(:error, :code))
        assert_equal "Internal error", response.dig(:error, :message)
        refute_includes JSON.generate(response), "secret-sdk-error"
        assert_deeply_frozen response
      end
    end
  end

  test "SDK envelope fields cannot override the Hitch wire contract" do
    fake_server = Object.new
    fake_server.define_singleton_method(:handle) do |_request|
      {
        "jsonrpc" => "1.0",
        "id" => "sdk-id",
        "result" => {},
        "attacker-field" => "secret-sdk-field"
      }
    end

    stub_class_method(::MCP::Server, :new, ->(**) { fake_server }) do
      response = call_adapter(method: "server/discover", request_id: "original-id")

      assert_equal "2.0", response.fetch(:jsonrpc)
      assert_equal "original-id", response.fetch(:id)
      refute response.key?("jsonrpc")
      refute response.key?("id")
      refute response.key?("attacker-field")
      refute_includes JSON.generate(response), "secret-sdk-field"
    end
  end

  private

  def adapter_class
    Hitch::MCP::Internal::SDKAdapter
  end

  def reserved_context_predicate(method:, arguments:)
    raw_internal_adapter(method:, arguments:).__send__(:reserved_server_context?)
  end

  def raw_internal_adapter(method:, arguments:)
    Hitch::MCP::Internal::SDKAdapter.new(
      verified_request: Hitch::MCP::Internal::JsonValues.deep_freeze(
        {
          "jsonrpc" => "2.0",
          "id" => "reserved-predicate",
          "method" => method,
          "params" => { "arguments" => arguments }
        }
      ),
      tools: [],
      context: Object.new,
      server_info: SERVER_INFO
    )
  end

  # The adapter's contract is VerifiedRequest's product: a deep-frozen,
  # string-keyed Hash. The helper honors it the way the endpoint does.
  def call_adapter(method:, params: {}, tools: [], context: Object.new, server_info: SERVER_INFO, request_id: "sdk_contract_request")
    adapter_class.call(
      verified_request: Hitch::MCP::Internal::JsonValues.deep_freeze(
        {
          "jsonrpc" => "2.0",
          "id" => request_id,
          "method" => method,
          "params" => params
        }
      ),
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
