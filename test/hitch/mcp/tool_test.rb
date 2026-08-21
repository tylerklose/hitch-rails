# frozen_string_literal: true

require "test_helper"
require "json"

class Hitch::MCP::ToolTest < ActiveSupport::TestCase
  test "base tool availability is exactly deny default" do
    assert_equal false, Hitch::MCP::Tool.available_to?(Object.new)
  end

  test "base tool policy and execution are exact deny default boundaries" do
    policy_error = assert_raises(Hitch::MCP::Forbidden) do
      Hitch::MCP::Tool.authorize!(Object.new, arguments: {}.freeze)
    end
    assert_instance_of Hitch::MCP::Forbidden, policy_error

    execution_error = assert_raises(RuntimeError) do
      Hitch::MCP::Tool.perform(Object.new, arguments: {}.freeze)
    end
    assert_instance_of RuntimeError, execution_error
    assert_equal "MCP tool perform must be implemented", execution_error.message
  end

  RUNTIME_TEST_NAMES = %w[
    test_schema_precedes_argument_policy
    test_top_level_reserved_context_fails_before_argument_policy
    test_default_policy_denies_without_execution
    test_Forbidden_policy_messages_stay_private_and_perform_never_runs
    test_host_exceptions_become_generic_tool_errors_after_one_execution_attempt
  ].freeze
  PROTOCOL_VERSION = "2026-07-28"
  SERVER_INFO = { "name" => "hitch-tool-test", "version" => "0.2.0" }.freeze
  INPUT_SCHEMA = {
    "type" => "object",
    "properties" => {
      "message" => { "type" => "string" },
      "nested" => { "type" => "object" }
    },
    "required" => [ "message" ],
    "additionalProperties" => false
  }.freeze

  Definition = Data.define(:tool_class, :input_schema) do
    def name = "policy.tool"
    def description = "Exercise Hitch's final argument policy boundary"
    def output_schema = nil
    def annotations = nil

    def call(server_context:, **arguments)
      tool_class.call(server_context:, **arguments)
    end
  end
  private_constant :Definition

  test "schema precedes argument policy" do
    calls = Hash.new(0)
    tool = build_tool(
      authorize: ->(_context, arguments:) { calls[:authorize] += 1 },
      perform: lambda { |_context, arguments:|
        calls[:perform] += 1
        successful_response
      }
    )

    response = call_tool(tool, arguments: { "message" => 7 })

    assert_generic_tool_error response
    assert_equal 0, calls[:authorize]
    assert_equal 0, calls[:perform]
  end

  test "top level reserved context fails before argument policy" do
    calls = Hash.new(0)
    tool = build_tool(
      authorize: ->(_context, arguments:) { calls[:authorize] += 1 },
      perform: lambda { |_context, arguments:|
        calls[:perform] += 1
        successful_response
      }
    )

    response = call_tool(tool, arguments: { "server_context" => "attacker-owned" })

    assert_equal(-32602, response.dig(:error, :code))
    assert_equal 0, calls[:authorize]
    assert_equal 0, calls[:perform]
  end

  test "policy and execution receive the same deeply frozen string keyed arguments" do
    context = Object.new
    observed = {}
    tool = build_tool(
      authorize: lambda { |received_context, arguments:|
        observed[:authorize_context] = received_context
        observed[:authorize_arguments] = arguments
      },
      perform: lambda { |received_context, arguments:|
        observed[:perform_context] = received_context
        observed[:perform_arguments] = arguments
        successful_response
      }
    )
    source = {
      "message" => +"hello",
      "nested" => {
        "server_context" => +"valid nested data",
        "items" => [ { "deep-key" => +"deep-value" } ]
      }
    }

    response = call_tool(tool, arguments: source, context:)

    assert_nil response[:error]
    assert_same context, observed.fetch(:authorize_context)
    assert_same context, observed.fetch(:perform_context)
    arguments = observed.fetch(:authorize_arguments)
    assert_same arguments, observed.fetch(:perform_arguments)
    assert_equal "valid nested data", arguments.dig("nested", "server_context")
    assert_equal "deep-value", arguments.dig("nested", "items", 0, "deep-key")
    assert_all_hash_keys_are_strings arguments
    assert_deeply_frozen arguments
    refute_same source, arguments
    refute_same source.fetch("message"), arguments.fetch("message")
  end

  test "default policy denies without execution" do
    perform_calls = 0
    tool = build_tool(perform: lambda { |_context, arguments:|
      perform_calls += 1
      successful_response
    })

    response = call_tool(tool)

    assert_generic_tool_error response
    assert_equal 0, perform_calls
  end

  test "Forbidden policy messages stay private and perform never runs" do
    perform_calls = 0
    tool = build_tool(
      authorize: ->(_context, arguments:) { raise Hitch::MCP::Forbidden, "policy-secret" },
      perform: lambda { |_context, arguments:|
        perform_calls += 1
        successful_response
      }
    )

    response = call_tool(tool)

    assert_generic_tool_error response
    assert_equal 0, perform_calls
    refute_includes JSON.generate(response), "policy-secret"
  end

  test "unexpected policy failures are generic and stop execution" do
    perform_calls = 0
    tool = build_tool(
      authorize: ->(_context, arguments:) { raise "unexpected-policy-secret" },
      perform: lambda { |_context, arguments:|
        perform_calls += 1
        successful_response
      }
    )

    response = call_tool(tool)

    assert_generic_tool_error response
    assert_equal 0, perform_calls
    refute_includes JSON.generate(response), "unexpected-policy-secret"
  end

  test "policy return values are ignored when no exception is raised" do
    perform_calls = 0
    tool = build_tool(
      authorize: ->(_context, arguments:) { false },
      perform: lambda { |_context, arguments:|
        perform_calls += 1
        successful_response
      }
    )

    response = call_tool(tool)

    assert_nil response[:error]
    assert_equal false, response.dig(:result, :isError)
    assert_equal 1, perform_calls
  end

  test "host exceptions become generic tool errors after one execution attempt" do
    calls = Hash.new(0)
    tool = build_tool(
      authorize: ->(_context, arguments:) { calls[:authorize] += 1 },
      perform: lambda { |_context, arguments:|
        calls[:perform] += 1
        raise "host-execution-secret"
      }
    )

    response = call_tool(tool)

    assert_generic_tool_error response
    assert_equal 1, calls[:authorize]
    assert_equal 1, calls[:perform]
    refute_includes JSON.generate(response), "host-execution-secret"
  end

  test "non JSON and duplicate normalized keys fail before policy" do
    authorize_calls = 0
    tool = build_tool(
      authorize: ->(_context, arguments:) { authorize_calls += 1 },
      perform: ->(_context, arguments:) { successful_response }
    )
    server_context = { hitch_context: Object.new }

    non_json = tool.call(server_context:, payload: Object.new)
    duplicate = tool.call(server_context:, **{ "same" => 1, same: 2 })

    assert_predicate non_json, :error?
    assert_predicate duplicate, :error?
    assert_equal 0, authorize_calls
  end

  test "framework call and Forbidden remain owned public boundaries" do
    subclass = Class.new(Hitch::MCP::Tool)

    assert_equal Hitch::MCP::Tool.singleton_class, subclass.method(:call).owner
    assert_respond_to subclass, :authorize!
    assert_respond_to subclass, :perform
    assert_operator Hitch::MCP::Forbidden, :<, StandardError
  end

  # A tool failure reaches the client as one flat generic error on purpose.
  # That is the wire's contract, not the developer's: locally the real
  # exception has to be readable, or the only way to debug a tool is to
  # bisect it by hand.
  test "a failing tool tells the developer locally and the client nothing" do
    tool = build_tool(
      authorize: ->(_context, arguments:) { nil },
      perform: ->(_context, arguments:) { raise ArgumentError, "the real bug" }
    )
    response = nil

    log = capture_hitch_log { response = call_tool(tool) }

    assert_generic_tool_error(response)
    assert_includes log, "failed during execution"
    assert_includes log, "ArgumentError: the real bug"
    assert_includes log, "tool_test.rb"
  end

  # The commonest first mistake: returning a bare value instead of a Result.
  # The exception for it is generic, so the category is what names it.
  test "a tool that forgets Result names the category locally" do
    tool = build_tool(
      authorize: ->(_context, arguments:) { nil },
      perform: ->(_context, arguments:) { "not a Result" }
    )

    log = capture_hitch_log { call_tool(tool) }

    assert_includes log, "failed during result (invalid_result_type)"
  end

  test "production is silent, and so is an ordinary denial" do
    raising = build_tool(
      authorize: ->(_context, arguments:) { nil },
      perform: ->(_context, arguments:) { raise ArgumentError, "the real bug" }
    )
    denying = build_tool(
      authorize: ->(_context, arguments:) { raise Hitch::MCP::Forbidden, "private reason" },
      perform: ->(_context, arguments:) { flunk "perform must not run" }
    )

    production = ActiveSupport::EnvironmentInquirer.new("production")
    production_log = stub_class_method(Rails, :env, -> { production }) do
      capture_hitch_log { call_tool(raising) }
    end
    assert_equal "", production_log

    # A denial is the policy working, not a failure to diagnose.
    assert_equal "", capture_hitch_log { call_tool(denying) }
  end

  private

  def capture_hitch_log
    buffer = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(buffer)
    yield
    buffer.string
  ensure
    Rails.logger = original
  end

  def build_tool(authorize: nil, perform:)
    Class.new(Hitch::MCP::Tool).tap do |tool|
      if authorize
        tool.define_singleton_method(:authorize!) do |context, arguments:|
          authorize.call(context, arguments:)
        end
      end
      tool.define_singleton_method(:perform) do |context, arguments:|
        perform.call(context, arguments:)
      end
    end
  end

  def call_tool(tool, arguments: { "message" => "hello" }, context: Object.new)
    adapter_class.call(
      verified_request: Hitch::MCP::Internal::JsonValues.deep_freeze(
        {
          "jsonrpc" => "2.0",
          "id" => "tool-policy-request",
          "method" => "tools/call",
          "params" => { "name" => "policy.tool", "arguments" => arguments }
        }
      ),
      tools: [ Definition.new(tool_class: tool, input_schema: INPUT_SCHEMA) ],
      context:,
      server_info: SERVER_INFO
    )
  end

  def adapter_class
    Hitch::MCP::Internal::SDKAdapter
  end

  def successful_response
    Hitch::MCP::Result.text("ok")
  end

  def assert_generic_tool_error(response)
    assert_nil response[:error]
    assert_equal true, response.dig(:result, :isError)
    assert_equal "Tool execution failed", response.dig(:result, :content, 0, :text)
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
        assert_predicate key, :frozen?
        assert_deeply_frozen child
      end
    when Array
      value.each { |child| assert_deeply_frozen(child) }
    end
  end
end
