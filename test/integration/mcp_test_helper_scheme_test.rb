# frozen_string_literal: true

require "test_helper"
require "hitch/mcp/test_helper"

# The generated tool test is an ActionDispatch::IntegrationTest, which speaks
# http, while every real resource_uri is https. That mismatch used to fail the
# host gate with a 400, an empty body, and nothing in the log — for want of one
# `https!` that appeared in no document and no error.
class McpTestHelperSchemeTest < ActionDispatch::IntegrationTest
  include Hitch::MCP::TestHelper

  setup do
    @principal = User.create!(email: "scheme-#{SecureRandom.hex(4)}@example.test")
    Hitch.reset_configuration!
    Hitch.configure do |configuration|
      configuration.resource_uri = "https://dummy.test/mcp"
      configuration.allowed_hosts = [ "dummy.test" ]
      configuration.mcp.enabled = true
      configuration.mcp.registry = "McpToolRegistry"
      configuration.mcp.rate_limit_store = ActiveSupport::Cache::MemoryStore.new
    end
    # Undo the suite-wide default, so this starts where a host's own generated
    # test starts.
    https!(false)
  end

  teardown { Hitch.reset_configuration! }

  test "post_mcp reaches an https endpoint without the host calling https!" do
    assert_equal "https", URI.parse(Hitch.configuration.resource_uri).scheme

    post_mcp(method: "tools/list", token: mint_mcp_token(principal: @principal))

    assert_response :success
    assert_kind_of Array, JSON.parse(response.body).dig("result", "tools")
  end
end
