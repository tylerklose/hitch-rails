# frozen_string_literal: true

class McpController < ActionController::API
  include Hitch::MCP::Endpoint

  if ENV["HITCH_CONFORMANCE_SERVER"] == "1"
    require Rails.root.join("../conformance/server/fixture_tools").to_s
  end

  class_attribute :wire_metrics, instance_accessor: false,
    default: Hash.new(0).freeze

  class << self
    def reset_wire_metrics!
      self.wire_metrics = Hash.new(0).freeze
    end

    def increment_wire_metric!(name)
      self.wire_metrics = wire_metrics.merge(name => wire_metrics.fetch(name, 0) + 1).freeze
    end
  end

  private

  def hitch_mcp_admit_authenticated_request(**)
    case request.get_header("HTTP_X_HITCH_WIRE_ADMISSION")
    when "reject" then { retry_after: 60 }
    when "raise" then raise "wire-admission-secret"
    else :allow
    end
  end

  def hitch_mcp_body_parse_started!
    self.class.increment_wire_metric!(:body_parses)
  end

  def hitch_mcp_registry_resolved!
    self.class.increment_wire_metric!(:registry)
  end

  def hitch_mcp_sdk_dispatch_started!
    self.class.increment_wire_metric!(:sdk)
  end

  def hitch_mcp_host_called!
    self.class.increment_wire_metric!(:host)
  end

  def hitch_mcp_tools
    return super unless ENV["HITCH_CONFORMANCE_SERVER"] == "1"

    on_invoke = lambda {
      hitch_mcp_invocation_observed!
      hitch_mcp_host_called!
    }
    (
      Hitch::Conformance::Server::FixtureTools.all(on_invoke:) +
      Hitch::Conformance::Server::FixtureTools.runner_diagnostics(on_invoke:)
    ).freeze
  end

  def hitch_mcp_request_observed!
    self.class.increment_wire_metric!(:request_events)
  end

  def hitch_mcp_invocation_observed!
    self.class.increment_wire_metric!(:invocation_events)
  end
end
