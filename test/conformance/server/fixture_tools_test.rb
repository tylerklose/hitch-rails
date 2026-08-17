# frozen_string_literal: true

require "test_helper"
require Rails.root.join("../conformance/server/fixture_tools").to_s

class ServerConformanceFixtureToolsTest < ActiveSupport::TestCase
  test "defines only the five reviewed fixture tools" do
    tools = Hitch::Conformance::Server::FixtureTools.all

    assert_equal %w[
      test_simple_text
      test_error_handling
      json_schema_2020_12_tool
      test_streaming_elicitation
      test_logging_tool
    ], tools.map(&:name)
    assert tools.all? { |tool| tool.description.present? && tool.input_schema.fetch("type") == "object" }
    assert_equal [ "test_missing_capability" ],
      Hitch::Conformance::Server::FixtureTools.runner_diagnostics.map(&:name)
  end

  test "simple text and intentional error exercise the official contracts" do
    tools = Hitch::Conformance::Server::FixtureTools.all
    simple = tools.find { |tool| tool.name == "test_simple_text" }
    response = simple.call(server_context: { hitch_context: Object.new })

    assert_includes response.content.first.fetch(:text), "simple text response"
    failure = tools.find { |tool| tool.name == "test_error_handling" }
    error_response = failure.call(server_context: { hitch_context: Object.new })
    assert_predicate error_response, :error?
    assert_includes error_response.content.first.fetch(:text), "intentionally returns an error"
  end

  test "preserves the full reviewed JSON Schema 2020-12 vocabulary" do
    tool = Hitch::Conformance::Server::FixtureTools.all.find do |candidate|
      candidate.name == "json_schema_2020_12_tool"
    end
    schema = tool.input_schema

    assert_equal "https://json-schema.org/draft/2020-12/schema", schema.fetch("$schema")
    assert_equal "addressDef", schema.dig("$defs", "address", "$anchor")
    assert schema.key?("allOf")
    assert schema.key?("if")
    assert schema.key?("then")
    assert schema.key?("else")
    assert_equal false, schema.fetch("additionalProperties")
  end

  test "verified wire accepts the protocol-optional omitted arguments member" do
    verifier = Hitch::MCP::Internal::VerifiedRequest
    raw = JSON.generate(
      jsonrpc: "2.0",
      id: "omitted-arguments",
      method: "tools/call",
      params: {
        name: "test_simple_text",
        _meta: {
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => {}
        }
      }
    )
    verified = verifier.call(
      raw_body: raw,
      headers: {
        protocol_version: "2026-07-28",
        method: "tools/call",
        name: "test_simple_text"
      }
    )

    refute verified.fetch("params").key?("arguments")
  end

  test "fixture infrastructure is not in the packaged runtime" do
    specification = Gem::Specification.load(Rails.root.join("../../hitch-rails.gemspec").to_s)

    refute specification.files.any? { |path| path.start_with?("test/conformance/") }
  end
end
