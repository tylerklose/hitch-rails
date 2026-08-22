# frozen_string_literal: true

require "test_helper"
require "hitch/mcp/test_helper"
require "rake"
require "tmpdir"

# A namespaced principal, which is what the polymorphic principal columns
# exist to support and what the task's PRINCIPAL parsing has to survive.
module Accounts
  class Operator < ApplicationRecord
    self.table_name = "users"
  end
end

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

      # The file is what someone runs through `cat`. It has to hold the token
      # and nothing else, or `Bearer $(cat agent.token)` is a silent 401.
      # One line, one value, no label — `$(...)` strips the trailing newline.
      assert_equal 1, File.readlines(path).length
      token = File.read(path).chomp
      refute_includes token, "="
      assert_equal 0o600, File.stat(path).mode & 0o777

      # The confirmation goes to stderr so a silent success is not mistaken
      # for a no-op, and it must never carry the secret.
      assert_empty stdout
      assert_includes stderr, "Issued an access token"
      refute_includes stderr, token

      record = Hitch::AccessToken.sole
      refute_includes record.attributes.values, token
      assert_equal record, Hitch::AccessToken.find_by_token(token)
      post_mcp(method: "tools/list", token: token)
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

  # Postgres casts "12 34" to 12, so an id typo used to issue a 90-day token
  # for a different person's account without a word.
  # Rails casts "12 34" to 12, so a typo used to issue a token for a
  # different person. The output path is writable here so a failure can only
  # come from the guard, not from the filesystem refusing the write.
  test "an integer id carrying junk aborts" do
    other = User.create!(email: "someone-else@example.test")

    Dir.mktmpdir("hitch-token") do |directory|
      [ "#{other.id} 99", "#{other.id}abc", " #{other.id}", "0x10" ].each do |sloppy|
        ENV["OUTPUT_FILE"] = File.join(directory, "token-#{sloppy.hash}")
        ENV["PRINCIPAL"] = "User:#{sloppy}"
        assert_raises(SystemExit, sloppy) { capture_io { Rake::Task[TASK].invoke } }
        Rake::Task[TASK].reenable
        assert_equal 0, Hitch::AccessToken.count, sloppy
      end
    end
  end

  test "a namespaced principal model resolves" do
    parsed = Hitch::TokenIssueTask.principal!("Accounts::Operator:#{@principal.id}")

    assert_instance_of Accounts::Operator, parsed
    assert_equal @principal.id, parsed.id
  end

  test "issuing refuses a blank client_id rather than minting a dead token" do
    error = assert_raises(ArgumentError) do
      Hitch::AccessToken.issue!(principal: @principal, client_id: "")
    end

    assert_includes error.message, "client_id"
    assert_equal 0, Hitch::AccessToken.count
  end

  test "expires_in takes seconds, not anything that answers to_i" do
    error = assert_raises(ArgumentError) do
      Hitch::AccessToken.issue!(principal: @principal, client_id: "cron-agent", expires_in: "90abc")
    end

    assert_includes error.message, "expires_in"
    assert_equal 0, Hitch::AccessToken.count
  end

  # The row is created before the exchange and dated after it. A failure
  # anywhere in that sequence must not leave a live credential nobody
  # received.
  test "a failure partway through leaves nothing behind" do
    stub_class_method(Hitch::AccessToken, :exchange_authorization_code!, ->(**) { nil }) do
      assert_raises(RuntimeError) do
        Hitch::AccessToken.issue!(principal: @principal, client_id: "cron-agent")
      end
    end

    assert_equal 0, Hitch::AccessToken.count
  end

  # A bare `transaction` joins a caller's open one and opens no savepoint, so
  # a host issuing inside its own transaction and rescuing kept the row. The
  # suite's own transactional fixtures are joinable: false, which forces a
  # savepoint and hides this — so the host's shape has to be built here.
  test "a host's own open transaction does not swallow the rollback" do
    swallowed = nil

    Hitch::AccessToken.transaction(joinable: true) do
      begin
        stub_class_method(Hitch::AccessToken, :exchange_authorization_code!, ->(**) { nil }) do
          Hitch::AccessToken.issue!(principal: @principal, client_id: "cron-agent")
        end
      rescue RuntimeError => error
        swallowed = error
      end
    end

    refute_nil swallowed
    assert_equal 0, Hitch::AccessToken.count
  end

  test "duplicate scopes cannot walk past the persisted scope boundary" do
    Hitch::AccessToken.issue!(principal: @principal, client_id: "cron-agent", scopes: [ "mcp" ] * 200)

    assert_equal "mcp", Hitch::AccessToken.sole.scopes
  end

  test "a principal that does not resolve aborts before issuing anything" do
    Dir.mktmpdir("hitch-token") do |directory|
      [ "", "User", "Nope:1", "User:999999", "ApplicationRecord:1" ].each do |value|
        ENV["OUTPUT_FILE"] = File.join(directory, "token-#{value.hash}")
        ENV["PRINCIPAL"] = value
        assert_raises(SystemExit, value) { capture_io { Rake::Task[TASK].invoke } }
        Rake::Task[TASK].reenable
        assert_equal 0, Hitch::AccessToken.count, value
      end
    end
  end

  # A Duration is the natural console spelling, including a fractional one.
  test "expires_in takes a number or a duration" do
    [ 1.5.hours, 3600, 3600.0, 2.days ].each do |lifetime|
      Hitch::AccessToken.delete_all
      Hitch::AccessToken.issue!(principal: @principal, client_id: "cron-agent", expires_in: lifetime)

      assert_in_delta lifetime.to_i.seconds.from_now, Hitch::AccessToken.sole.expires_at, 5.seconds
    end
  end

  # The rake task parses ENV; a String reaching the method is a mistake, and
  # guessing at it is how "0700" came to mean 448 seconds.
  test "expires_in refuses a string rather than guessing its base" do
    [ "3600", "0700", "90abc" ].each do |bad|
      assert_raises(ArgumentError, bad) do
        Hitch::AccessToken.issue!(principal: @principal, client_id: "cron-agent", expires_in: bad)
      end
    end

    assert_equal 0, Hitch::AccessToken.count
  end

  test "the public method caps the lifetime too, not just the task" do
    assert_raises(ArgumentError) do
      Hitch::AccessToken.issue!(
        principal: @principal, client_id: "cron-agent", expires_in: 300_000_000_000
      )
    end

    assert_equal 0, Hitch::AccessToken.count
  end

  test "a lifetime past the cap aborts rather than overflowing the column" do
    Dir.mktmpdir("hitch-token") do |directory|
      ENV["OUTPUT_FILE"] = File.join(directory, "token")
      ENV["PRINCIPAL"] = "User:#{@principal.id}"
      ENV["EXPIRES_IN_DAYS"] = "99999999999"

      assert_raises(SystemExit) { capture_io { Rake::Task[TASK].invoke } }

      assert_equal 0, Hitch::AccessToken.count
    end
  end
end
