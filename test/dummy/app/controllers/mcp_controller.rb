# frozen_string_literal: true

class McpController < ActionController::API
  include Hitch::MCP::Endpoint

  # The sealed M2 wire vectors retain their transport-only invocation fixture,
  # but it is test application code and is no longer packaged with Hitch.
  class WireSliceTool
    NAME = "hitch.echo"
    DESCRIPTION = "Echo one bounded message through the authenticated Hitch transport"
    INPUT_SCHEMA = {
      "type" => "object",
      "required" => [ "message" ].freeze,
      "properties" => {
        "message" => { "type" => "string", "maxLength" => 1_000 }.freeze,
        "nested" => { "type" => "object" }.freeze
      }.freeze,
      "additionalProperties" => true
    }.freeze

    def initialize(on_invoke:)
      @on_invoke = on_invoke
    end

    def name = NAME
    def description = DESCRIPTION
    def input_schema = INPUT_SCHEMA
    def output_schema = nil
    def annotations
      {
        read_only_hint: true,
        destructive_hint: false,
        idempotent_hint: true,
        open_world_hint: false
      }.freeze
    end

    def call(server_context:, **arguments)
      @on_invoke.call
      message = arguments.fetch(:message)
      ::MCP::Tool::Response.new(
        [ { type: "text", text: message } ],
        structured_content: { "message" => message }
      )
    end
  end
  private_constant :WireSliceTool

  if ENV["HITCH_CONFORMANCE_SERVER"] == "1"
    require Rails.root.join("../conformance/server/fixture_tools").to_s
  end

  class_attribute :wire_metrics, instance_accessor: false,
    default: Hash.new(0).freeze
  class_attribute :wire_slice_enabled, instance_accessor: false, default: false

  class << self
    def reset_wire_metrics!
      self.wire_metrics = Hash.new(0).freeze
    end

    def increment_wire_metric!(name)
      self.wire_metrics = wire_metrics.merge(name => wire_metrics.fetch(name, 0) + 1).freeze
    end
  end

  private

  # Returns a running count, matching Hitch::MCP::Endpoint. A nil means the
  # configured store cannot count, which admits the request.
  def hitch_mcp_admit_authenticated_request(**identity)
    case request.get_header("HTTP_X_HITCH_WIRE_ADMISSION")
    when "reject" then Hitch.configuration.mcp.request_limit.fetch(:to) + 1
    when "raise" then raise "wire-admission-secret"
    when "runtime" then super(**identity)
    end
  end

  def hitch_mcp_host_called!
    self.class.increment_wire_metric!(:host)
  end

  def hitch_mcp_tools(verified_request:, context:, snapshot:)
    on_invoke = lambda {
      hitch_mcp_invocation_observed!
      hitch_mcp_host_called!
    }
    if ENV["HITCH_CONFORMANCE_SERVER"] == "1"
      return (
        Hitch::Conformance::Server::FixtureTools.all(on_invoke:) +
        Hitch::Conformance::Server::FixtureTools.runner_diagnostics(on_invoke:)
      ).freeze
    end
    return [ WireSliceTool.new(on_invoke:) ].freeze if self.class.wire_slice_enabled

    super
  end

  def hitch_mcp_request_observed!
    super
    self.class.increment_wire_metric!(:request_events)
  end

  def hitch_mcp_invocation_observed!
    self.class.increment_wire_metric!(:invocation_events)
  end
end
