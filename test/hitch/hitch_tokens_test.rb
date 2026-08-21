# frozen_string_literal: true

require "test_helper"
require "hitch/mcp/test_helper"
require "rake"
require "tmpdir"

# The point of a console-issued token is that a headless agent can use it, so
# every assertion here ends at the real endpoint rather than at the row.
class HitchTokensTaskTest < ActionDispatch::IntegrationTest
  include Hitch::MCP::TestHelper

  TASK = "hitch:tokens:issue"

  setup do
    Hitch::AccessToken.delete_all
    User.delete_all
    @principal = User.create!(email: "headless-agent@example.test")
    Rails.application.load_tasks unless Rake::Task.task_defined?(TASK)
    @original_env = ENV.to_h

    # Every MCP test in this suite configures Hitch itself; ambient
    # configuration is whatever the last test left behind.
    Hitch.reset_configuration!
    Hitch.configure do |configuration|
      configuration.resource_uri = "https://dummy.test/mcp"
      configuration.allowed_hosts = [ "dummy.test" ]
      configuration.mcp.enabled = true
      configuration.mcp.registry = "McpToolRegistry"
      configuration.mcp.rate_limit_store = ActiveSupport::Cache::MemoryStore.new
    end
    Hitch.configuration.mcp.prepare_registry!(
      supported_scopes: Hitch.configuration.supported_scopes
    )
  end

  teardown do
    ENV.replace(@original_env)
    Rake::Task[TASK].reenable if Rake::Task.task_defined?(TASK)
    Hitch.reset_configuration!
    Hitch::AccessToken.delete_all
    User.delete_all
  end

  test "an issued token drives the real endpoint" do
    token = Hitch::AccessToken.issue!(principal: @principal, client_id: "cron-agent")

    post_mcp(method: "tools/list", token: token)

    assert_response :success
    assert JSON.parse(response.body).dig("result", "tools").is_a?(Array)
  end

  test "only the digest is stored, and the raw token is disclosed once at 0600" do
    Dir.mktmpdir("hitch-token") do |directory|
      path = File.join(directory, "agent.token")
      ENV["OUTPUT_FILE"] = path
      ENV["PRINCIPAL"] = "User:#{@principal.id}"
      ENV["CLIENT_ID"] = "cron-agent"

      stdout, stderr = capture_io { Rake::Task[TASK].invoke }

      assert_empty stdout
      assert_empty stderr
      assert_equal 0o600, File.stat(path).mode & 0o777
      token = File.read(path).lines.map(&:chomp).filter_map do |line|
        line.delete_prefix("access_token=") if line.start_with?("access_token=")
      end
      assert_equal 1, token.length

      record = Hitch::AccessToken.sole
      refute_includes record.attributes.values, token.first
      assert_equal record, Hitch::AccessToken.find_by_token(token.first)
      post_mcp(method: "tools/list", token: token.first)
      assert_response :success
    end
  end

  test "the agent chooses its own lifetime, not the browser session's" do
    Hitch::AccessToken.issue!(principal: @principal, client_id: "cron-agent", expires_in: 90 * 86_400)

    assert_in_delta 90.days.from_now, Hitch::AccessToken.sole.expires_at, 5.seconds
  end

  test "issuing refuses a scope the server does not support" do
    error = assert_raises(ArgumentError) do
      Hitch::AccessToken.issue!(principal: @principal, client_id: "cron-agent", scopes: [ "admin" ])
    end

    assert_includes error.message, "admin"
    assert_equal 0, Hitch::AccessToken.count
  end

  test "a principal that does not resolve aborts before issuing anything" do
    ENV["OUTPUT_FILE"] = "/unused"
    [ "", "User", "Nope:1", "User:999999" ].each do |value|
      ENV["PRINCIPAL"] = value
      assert_raises(SystemExit) { capture_io { Rake::Task[TASK].invoke } }
      Rake::Task[TASK].reenable
    end

    assert_equal 0, Hitch::AccessToken.count
  end
end
