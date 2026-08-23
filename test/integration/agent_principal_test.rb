# frozen_string_literal: true

require "test_helper"
require "hitch/mcp/test_helper"

# A principal is any persisted record, not necessarily a person. An agent
# holds its own account: it is issued a token directly, because it has no
# browser session for the consent screen to resolve a principal from.
#
# Agent keys on a string primary key on purpose. Hitch stores principal_id as
# a string so a host may key principals on integer, UUID, or ULID — before
# this test every principal in the suite was an integer-keyed User, so that
# claim was documented and executed nowhere.
module AgentPrincipalFixtures
  class Whoami < Hitch::MCP::Tool
    tool_name "whoami"
    description "Reports the calling principal"
    input_schema(type: "object", properties: {}, additionalProperties: false)
    annotations read_only_hint: true,
      destructive_hint: false,
      idempotent_hint: true,
      open_world_hint: false

    def self.available_to?(context) = context.principal.is_a?(Agent)

    # Returning without raising allows the call.
    def self.authorize!(_context, arguments:) = nil

    def self.perform(context, arguments:)
      Hitch::MCP::Result.text("agent #{context.principal.name} (#{context.principal.id})")
    end
  end

  class Registry < Hitch::MCP::Registry
    register Whoami, scopes: [ "mcp" ]
  end
end

class AgentPrincipalTest < ActionDispatch::IntegrationTest
  include Hitch::MCP::TestHelper

  RESOURCE = "https://dummy.test/mcp"

  setup do
    Hitch::AccessToken.delete_all
    Agent.delete_all
    User.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |configuration|
      configuration.resource_uri = RESOURCE
      configuration.supported_scopes = [ "mcp" ]
      configuration.mcp.enabled = true
      configuration.mcp.registry = "AgentPrincipalFixtures::Registry"
      configuration.mcp.server_info = { name: "hitch-agent-principal", version: "1" }
    end
    Hitch.configuration.mcp.prepare_registry!(supported_scopes: Hitch.configuration.supported_scopes)
    @agent = Agent.create!(name: "nightly")
    @token = mint_mcp_token(principal: @agent)
  end

  teardown do
    Hitch.reset_configuration!
    Hitch::AccessToken.delete_all
    Agent.delete_all
    User.delete_all
  end

  test "a non-integer-keyed agent is a principal end to end" do
    post_mcp(method: "tools/call", token: @token,
      params: { name: "whoami", arguments: {} })

    assert_response :ok
    text = JSON.parse(response.body).dig("result", "content", 0, "text")
    assert_equal "agent nightly (#{@agent.id})", text
  end

  test "the agent's id survives the round trip as its own string" do
    refute_match(/\A\d+\z/, @agent.id, "fixture stopped exercising a non-integer key")

    stored = Hitch::AccessToken.order(:id).last
    assert_equal "Agent", stored.principal_type
    assert_equal @agent.id, stored.principal_id
    assert_equal @agent, stored.principal
  end

  test "a tool opened only to agents stays closed to a person" do
    user = User.create!(email: "person@example.test")

    post_mcp(method: "tools/list", token: mint_mcp_token(principal: user))

    assert_response :ok
    names = JSON.parse(response.body).dig("result", "tools").map { |tool| tool.fetch("name") }
    assert_empty names, "whoami was listed for a User — availability is not reading the principal"
  end
end
