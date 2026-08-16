# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

class Hitch::MCP::ResultTest < ActiveSupport::TestCase
  RUNTIME_TEST_NAMES = %w[
    test_only_Result_is_accepted
    test_output_schema_and_exact_wire_cap
    test_failure_canaries_never_cross_Hitch_boundaries
  ].freeze
  PROTOCOL_VERSION = "2026-07-28"
  SERVER_INFO = { "name" => "hitch-result-test", "version" => "0.2.0" }.freeze
  INPUT_SCHEMA = { "type" => "object", "additionalProperties" => true }.freeze
  JSON_TYPES_SCHEMA = {
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "type" => [ "null", "boolean", "number", "string", "array", "object" ]
  }.freeze

  Definition = Data.define(:tool_class, :output_schema) do
    def name = "result.tool"
    def description = "Exercise Hitch's closed Result boundary"
    def input_schema = INPUT_SCHEMA
    def annotations = nil

    def call(server_context:, **arguments)
      tool_class.call(server_context:, **arguments)
    end
  end
  private_constant :Definition

  class ErrorSubscriber
    attr_reader :reports, :log

    def initialize
      @reports = []
      @log = StringIO.new
    end

    def report(error, handled:, severity:, context:, source:)
      report = { error:, handled:, severity:, context:, source: }
      reports << report
      log << JSON.generate(
        error_class: error.class.name,
        error_message: error.message,
        handled:,
        severity:,
        context:,
        source:
      )
    end
  end
  private_constant :ErrorSubscriber

  setup do
    @original_max_result_bytes = Hitch.configuration.mcp.max_result_bytes
    Hitch.configuration.mcp.max_result_bytes = 1_048_576
  end

  teardown do
    Hitch.configuration.mcp.max_result_bytes = @original_max_result_bytes
  end

  test "structured accepts every JSON primitive and container" do
    values = [
      nil,
      false,
      true,
      0,
      -7,
      1.25,
      "text",
      [ nil, true, 3, "nested", { "key" => "value" } ],
      { "array" => [ 1, 2 ], "object" => { "deep" => false } }
    ]

    values.each do |value|
      response = call_result(
        output_schema: JSON_TYPES_SCHEMA,
        perform: -> { Hitch::MCP::Result.structured(value) }
      )

      assert_nil response[:error], value.inspect
      assert_equal false, response.dig(:result, :isError), value.inspect
      actual = response.dig(:result, :structuredContent)
      value.nil? ? assert_nil(actual) : assert_equal(value, actual, value.inspect)
    end
  end

  test "constructors copy host values and expose no public generic constructor" do
    source_text = +"before"
    source_value = { +"key" => [ +"value" ] }
    text_result = Hitch::MCP::Result.text(source_text)
    structured_result = Hitch::MCP::Result.structured(source_value, text: "summary")

    source_text.replace("after")
    source_value.values.first.first.replace("changed")
    source_value["added"] = "changed"

    text_response = call_result(perform: -> { text_result })
    structured_response = call_result(
      output_schema: { "type" => "object" },
      perform: -> { structured_result }
    )

    assert_equal "before", text_response.dig(:result, :content, 0, :text)
    assert_equal({ "key" => [ "value" ] }, structured_response.dig(:result, :structuredContent))
    assert_predicate text_result, :frozen?
    assert_predicate structured_result, :frozen?
    refute_respond_to Hitch::MCP::Result, :new
    refute_respond_to Hitch::MCP::Result, :allocate
  end

  test "only Result is accepted" do
    impostor = Class.new do
      def to_h = { content: [ { type: "text", text: "impostor-canary" } ] }
    end.new
    allocated_result = Hitch::MCP::Result.__send__(:allocate)
    forged_subclass = Class.new(Hitch::MCP::Result).__send__(:allocate)
    values = [
      {},
      Object.new,
      RuntimeError.new("exception-result-canary"),
      User.new(email: "model-result-canary@example.test"),
      ::MCP::Tool::Response.new([ { type: "text", text: "sdk-result-canary" } ]),
      impostor,
      allocated_result,
      forged_subclass
    ]

    _responses, reports, report_log = capture_reports do
      values.map do |value|
        call_result(perform: -> { value }).tap { |response| assert_generic_tool_error(response) }
      end
    end

    assert_equal values.length, reports.length
    reports.each { |report| assert_report_category report, "invalid_result_type" }
    refute_match(/impostor-canary|exception-result-canary|model-result-canary|sdk-result-canary/, report_log)
  end

  test "invalid constructor values become generic reported failures" do
    recursive = []
    recursive << recursive
    invalid_builders = [
      -> { Hitch::MCP::Result.text(:symbol) },
      -> { Hitch::MCP::Result.error(Object.new) },
      -> { Hitch::MCP::Result.structured({ symbol: "value" }) },
      -> { Hitch::MCP::Result.structured(Float::INFINITY) },
      -> { Hitch::MCP::Result.structured(Object.new) },
      -> { Hitch::MCP::Result.structured(recursive) }
    ]

    _responses, reports, = capture_reports do
      invalid_builders.map do |builder|
        call_result(output_schema: JSON_TYPES_SCHEMA, perform: builder).tap do |response|
          assert_generic_tool_error response
        end
      end
    end

    assert_equal invalid_builders.length, reports.length
  end

  test "structured results require and satisfy the registered output schema" do
    missing, missing_reports, = capture_reports do
      call_result(perform: -> { Hitch::MCP::Result.structured({ "value" => 1 }) })
    end
    mismatch, mismatch_reports, = capture_reports do
      call_result(
        output_schema: {
          "type" => "object",
          "required" => [ "value" ],
          "properties" => { "value" => { "type" => "integer" } }
        },
        perform: -> { Hitch::MCP::Result.structured({ "value" => "schema-canary" }) }
      )
    end
    text_only, text_only_reports, = capture_reports do
      call_result(
        output_schema: { "type" => "object" },
        perform: -> { Hitch::MCP::Result.text("text-only-schema-canary") }
      )
    end

    assert_generic_tool_error missing
    assert_generic_tool_error mismatch
    assert_generic_tool_error text_only
    assert_equal 1, missing_reports.length
    assert_equal 1, mismatch_reports.length
    assert_equal 1, text_only_reports.length
    assert_report_category missing_reports.fetch(0), "missing_output_schema"
    assert_report_category mismatch_reports.fetch(0), "output_schema_mismatch"
    assert_report_category text_only_reports.fetch(0), "output_schema_mismatch"
    refute_includes JSON.generate(mismatch), "schema-canary"
    refute_includes JSON.generate(text_only), "text-only-schema-canary"
  end

  test "output schema and exact wire cap" do
    text = "line\nwith ünicode"
    structured = { "value" => "bounded" }
    structured_text = "structured summary"
    public_error = "approved public error"
    cases = [
      {
        output_schema: nil,
        result: -> { Hitch::MCP::Result.text(text) },
        canonical: { content: [ { type: "text", text: text } ], isError: false },
        expected_text: text,
        explicit_error: false
      },
      {
        output_schema: { "type" => "object" },
        result: -> { Hitch::MCP::Result.structured(structured, text: structured_text) },
        canonical: {
          content: [ { type: "text", text: structured_text } ],
          isError: false,
          structuredContent: structured
        },
        expected_text: structured_text,
        explicit_error: false
      },
      {
        output_schema: nil,
        result: -> { Hitch::MCP::Result.error(public_error) },
        canonical: { content: [ { type: "text", text: public_error } ], isError: true },
        expected_text: public_error,
        explicit_error: true
      }
    ]

    cases.each do |vector|
      exact_bytes = JSON.generate(vector.fetch(:canonical), max_nesting: false).bytesize
      Hitch.configuration.mcp.max_result_bytes = exact_bytes
      exact = call_result(output_schema: vector.fetch(:output_schema), perform: vector.fetch(:result))

      assert_nil exact[:error]
      assert_equal vector.fetch(:expected_text), exact.dig(:result, :content, 0, :text)

      Hitch.configuration.mcp.max_result_bytes = exact_bytes - 1
      over, reports, = capture_reports do
        call_result(output_schema: vector.fetch(:output_schema), perform: vector.fetch(:result))
      end
      assert_generic_tool_error over
      assert_equal 1, reports.length
      assert_report_category reports.fetch(0), "result_too_large"
      if vector.fetch(:explicit_error)
        refute_includes JSON.generate(over), vector.fetch(:expected_text)
      end
    end
  end

  test "serialization failures are generic for every Result kind" do
    invalid_text = "\xFF".dup.force_encoding(Encoding::UTF_8)
    builders = [
      [ nil, -> { Hitch::MCP::Result.text(invalid_text) } ],
      [ JSON_TYPES_SCHEMA, -> { Hitch::MCP::Result.structured(invalid_text) } ],
      [ nil, -> { Hitch::MCP::Result.error(invalid_text) } ]
    ]

    _responses, reports, = capture_reports do
      builders.map do |output_schema, builder|
        call_result(output_schema:, perform: builder).tap { |response| assert_generic_tool_error(response) }
      end
    end

    assert_equal builders.length, reports.length
    reports.each { |report| assert_report_category report, "serialization_failure" }
  end

  test "Result error is the only message preserving failure" do
    public_message = "You may retry this safe operation"
    response, reports, report_log = capture_reports do
      call_result(perform: -> { Hitch::MCP::Result.error(public_message) })
    end

    assert_nil response[:error]
    assert_equal true, response.dig(:result, :isError)
    assert_equal public_message, response.dig(:result, :content, 0, :text)
    assert_empty reports
    assert_empty report_log
    refute response.fetch(:result).key?(:structuredContent)
  end

  test "expected policy denial is not reported and reporter failure cannot alter the response" do
    denied, denial_reports, = capture_reports do
      call_result(
        authorize: -> { raise Hitch::MCP::Forbidden, "private-policy-canary" },
        perform: -> { flunk "perform must not run after policy denial" }
      )
    end
    assert_generic_tool_error denied
    assert_empty denial_reports
    refute_includes JSON.generate(denied), "private-policy-canary"

    failing_reporter = Object.new
    failing_reporter.define_singleton_method(:report) do |*|
      raise SystemStackError, "reporter-failure-canary"
    end
    response = stub_class_method(Rails, :error, -> { failing_reporter }) do
      call_result(perform: -> { raise "host-failure-canary" })
    end

    assert_generic_tool_error response
    refute_match(/reporter-failure-canary|host-failure-canary/, JSON.generate(response))
  end

  test "system stack failures remain generic" do
    response, reports, report_log = capture_reports do
      call_result(perform: -> { raise SystemStackError, "stack-failure-canary" })
    end

    assert_generic_tool_error response
    assert_equal 1, reports.length
    assert_report_category reports.fetch(0), "host_execution"
    refute_match(/stack-failure-canary/, JSON.generate(response) + report_log)
  end

  test "client request IDs never enter error reporting" do
    client_request_id = "eyJhbGciOiJIUzI1NiJ9.secret.signature"
    context = result_context(request_id: client_request_id)

    response, reports, report_log = capture_reports do
      call_result(context:, perform: -> { raise "request-id-host-canary" })
    end

    assert_generic_tool_error response
    assert_equal 1, reports.length
    refute reports.fetch(0).fetch(:context).key?(:hitch_mcp_request_id)
    refute_match(/#{Regexp.escape(client_request_id)}|request-id-host-canary/,
      JSON.generate(response) + report_log)
  end

  test "failure canaries never cross Hitch boundaries" do
    canaries = %w[
      argument-canary
      host-exception-canary
      principal-canary
      token-canary
      scope-canary
      client-canary
      meta-canary
    ]
    context = result_context(
      principal: Object.new.tap { |value| value.define_singleton_method(:inspect) { "principal-canary" } },
      access_token: Object.new.tap { |value| value.define_singleton_method(:inspect) { "token-canary" } },
      scope: Object.new.tap { |value| value.define_singleton_method(:inspect) { "scope-canary" } },
      client_id: "client-canary",
      meta: { "meta-canary" => "meta-canary" }
    )

    response, reports, report_log = capture_reports do
      call_result(
        arguments: { "secret" => "argument-canary" },
        context:,
        perform: -> { raise "host-exception-canary" }
      )
    end

    assert_generic_tool_error response
    assert_equal 1, reports.length
    report = reports.fetch(0)
    assert_equal "Hitch MCP tool execution failed", report.fetch(:error).message
    assert_nil report.fetch(:error).cause
    assert_equal true, report.fetch(:handled)
    assert_equal :error, report.fetch(:severity)
    assert_equal "hitch.mcp.tool", report.fetch(:source)
    assert_equal "host_execution", report.dig(:context, :hitch_mcp_category)
    assert_equal "result.tool", report.dig(:context, :hitch_mcp_tool)
    assert_nil report.dig(:context, :hitch_mcp_request_id)

    observed = JSON.generate(response) + report_log + report.fetch(:error).backtrace.join
    canaries.each { |canary| refute_includes observed, canary }
  end

  test "direct result normalizer fixes type limit cap and explicit error marker" do
    normalizer = result_normalizer_class
    invalid_results = [ Object.new, {}, Class.new(Hitch::MCP::Result).__send__(:allocate) ]
    invalid_results.each do |value|
      assert_normalizer_failure(:invalid_result_type) do
        normalizer.call(result: value, output_schema: nil, max_bytes: 1_000)
      end
    end
    [ nil, "1000", 0, -1, 1.0 ].each do |limit|
      assert_normalizer_failure(:invalid_result_limit) do
        normalizer.call(result: Hitch::MCP::Result.text("ok"), output_schema: nil, max_bytes: limit)
      end
    end

    text_result = Hitch::MCP::Result.text("direct text")
    canonical = { content: [ { type: "text", text: "direct text" } ], isError: false }
    exact_bytes = JSON.generate(canonical, max_nesting: false).bytesize
    response = normalizer.call(result: text_result, output_schema: nil, max_bytes: exact_bytes)
    assert_instance_of normalizer.const_get(:SDKResponse, false), response
    assert_equal canonical, response.to_h
    assert_equal true, response.content_provided?
    assert_nil normalizer.explicit_error_text(response.to_h)
    assert_normalizer_failure(:result_too_large) do
      normalizer.call(result: text_result, output_schema: nil, max_bytes: exact_bytes - 1)
    end

    public_error = "approved direct error"
    error_response = normalizer.call(
      result: Hitch::MCP::Result.error(public_error),
      output_schema: nil,
      max_bytes: 1_000
    )
    internal_result = error_response.instance_variable_get(:@hitch_result)
    assert_predicate internal_result, :frozen?
    assert_predicate internal_result.fetch(:_meta), :frozen?
    assert_equal public_error, normalizer.explicit_error_text(error_response.to_h)
    assert_equal true, error_response.content_provided?
  end

  test "direct result normalizer translates system stack failure to one category" do
    normalizer = result_normalizer_class
    instance = normalizer.new(Hitch::MCP::Result.text("ok"), nil, 1_000)
    instance.define_singleton_method(:canonical_result) { raise SystemStackError, "direct-stack-canary" }

    assert_normalizer_failure(:serialization_failure) { instance.call }
  end

  test "direct error normalizer fixes the generic response and denial classification" do
    normalizer = error_normalizer_class
    response = normalizer.__send__(:generic_response)
    assert_instance_of ::MCP::Tool::Response, response
    assert_equal({
      content: [ { type: "text", text: "Tool execution failed" } ],
      isError: true
    }, response.to_h)
    assert_equal true, response.content_provided?

    forbidden_subclass = Class.new(Hitch::MCP::Forbidden)
    [ Hitch::MCP::Forbidden.new, forbidden_subclass.new ].each do |error|
      assert_equal true, normalizer.__send__(:expected_denial?, error, :authorization)
      %i[context arguments execution result].each do |phase|
        assert_equal false, normalizer.__send__(:expected_denial?, error, phase)
      end
    end
    assert_equal false, normalizer.__send__(:expected_denial?, RuntimeError.new, :authorization)
    assert_equal false, normalizer.__send__(:expected_denial?, Object.new, :authorization)
  end

  test "direct error reporting context admits only fixed categories safe tool names and correlation ids" do
    normalizer = error_normalizer_class
    observation = Hitch::MCP.const_get(:Internal, false).const_get(:Observation, false)
    request_id = "b" * 32
    phases = {
      context: "context_handoff",
      arguments: "argument_normalization",
      authorization: "argument_policy",
      execution: "host_execution",
      result: "result_normalization",
      unknown: "tool_boundary"
    }

    stub_class_method(observation, :current_request_id, -> { request_id }) do
      phases.each do |phase, category|
        tool_name = "safe.tool-_#{phase}"
        context = normalizer.__send__(
          :reporting_context,
          error: RuntimeError.new("private-message"),
          phase:,
          tool_name:
        )
        assert_equal category, context.fetch(:hitch_mcp_category)
        assert_equal tool_name, context.fetch(:hitch_mcp_tool)
        assert_not_same tool_name, context.fetch(:hitch_mcp_tool)
        assert_predicate context.fetch(:hitch_mcp_tool), :frozen?
        assert_equal request_id, context.fetch(:hitch_mcp_request_id)
        assert_not_same request_id, context.fetch(:hitch_mcp_request_id)
        assert_predicate context.fetch(:hitch_mcp_request_id), :frozen?
        assert_predicate context, :frozen?
        refute_includes context.inspect, "private-message"
      end
    end

    string_subclass = Class.new(String).new("subclass.tool")
    [ nil, Object.new, string_subclass, "", "a" * 65, "unsafe/name", "token shaped value" ].each do |tool_name|
      stub_class_method(observation, :current_request_id, -> { nil }) do
        context = normalizer.__send__(
          :reporting_context,
          error: RuntimeError.new,
          phase: :execution,
          tool_name:
        )
        assert_equal({ hitch_mcp_category: "host_execution" }, context)
      end
    end

    failure_class = result_normalizer_class.const_get(:Failure, false)
    stub_class_method(observation, :current_request_id, -> { nil }) do
      context = normalizer.__send__(
        :reporting_context,
        error: failure_class.new(:result_too_large),
        phase: :result,
        tool_name: nil
      )
      assert_equal "result_too_large", context.fetch(:hitch_mcp_category)
      assert_predicate context.fetch(:hitch_mcp_category), :frozen?
    end
  end

  private

  def call_result(
    output_schema: nil,
    perform:,
    arguments: {},
    context: result_context,
    authorize: -> { }
  )
    tool = Class.new(Hitch::MCP::Tool)
    tool.tool_name("result.tool")
    tool.output_schema(output_schema) if output_schema
    tool.define_singleton_method(:authorize!) do |_context, arguments:|
      authorize.call
    end
    tool.define_singleton_method(:perform) do |_context, arguments:|
      perform.call
    end

    adapter_class.call(
      verified_request: {
        "jsonrpc" => "2.0",
        "id" => "result-request",
        "method" => "tools/call",
        "params" => { "name" => "result.tool", "arguments" => arguments }
      },
      tools: [ Definition.new(tool_class: tool, output_schema:) ],
      context:,
      server_info: SERVER_INFO
    )
  end

  def adapter_class
    Hitch::MCP.const_get(:SDKAdapter, false)
  end

  def result_normalizer_class
    Hitch::MCP.const_get(:Internal, false).const_get(:ResultNormalizer, false)
  end

  def error_normalizer_class
    Hitch::MCP.const_get(:Internal, false).const_get(:ErrorNormalizer, false)
  end

  def result_context(
    principal: Object.new,
    access_token: Object.new,
    scope: nil,
    client_id: "safe-client",
    request_id: "safe-request-id",
    meta: {}
  )
    Hitch::MCP::Context.new(
      principal:,
      access_token:,
      scope:,
      granted_scopes: [ "mcp" ],
      client_id:,
      resource: "https://result.test/mcp",
      request_id:,
      remote_ip: "198.51.100.12",
      user_agent: nil,
      protocol_version: PROTOCOL_VERSION,
      meta:
    )
  end

  def capture_reports
    subscriber = ErrorSubscriber.new
    Rails.error.subscribe(subscriber)
    response = yield
    [ response, subscriber.reports, subscriber.log.string ]
  ensure
    Rails.error.unsubscribe(subscriber) if subscriber
  end

  def assert_generic_tool_error(response)
    assert_nil response[:error]
    assert_equal true, response.dig(:result, :isError)
    assert_equal "Tool execution failed", response.dig(:result, :content, 0, :text)
  end

  def assert_report_category(report, category)
    assert_equal category, report.dig(:context, :hitch_mcp_category)
  end

  def assert_normalizer_failure(category)
    error = assert_raises(StandardError) { yield }
    assert_equal category, result_normalizer_class.failure_category(error)
    assert_equal "Hitch MCP result normalization failed", error.message
  end
end
