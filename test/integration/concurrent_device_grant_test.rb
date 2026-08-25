# frozen_string_literal: true

require "test_helper"
require "securerandom"

# The device grant's single-winner guards, driven through real independent
# connections. Runs on both adapters via bin/ci-migrations: SQLite and
# PostgreSQL disagree about locking enough that only the pair proves the
# conditional-UPDATE transitions.
class ConcurrentDeviceGrantTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  RESOURCE = "https://example.test/mcp"

  setup do
    Hitch::DeviceGrant.delete_all
    Hitch::AccessToken.delete_all
    User.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |config|
      config.resource_uri = RESOURCE
      config.device_authorization_enabled = true
    end
    @user = User.create!(email: "concurrent-device@test")
  end

  teardown do
    Hitch::DeviceGrant.delete_all
    Hitch::AccessToken.delete_all
    User.delete_all
  end

  def race(count)
    ready = Queue.new
    start = Queue.new
    workers = count.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          yield index
        end
      end
    end
    count.times { ready.pop }
    count.times { start << true }
    workers.map(&:value)
  end

  test "simultaneous polls of an approved grant mint exactly one token" do
    grant = Hitch::DeviceGrant.mint!(
      client_id: "concurrent-device", scopes: "mcp", resource_uri: RESOURCE
    )
    assert Hitch::DeviceGrant.approve!(user_code: grant.raw_user_code, principal: @user)

    results = race(2) do
      Hitch::DeviceGrant.exchange_device_code!(
        raw_device_code: grant.raw_device_code,
        client_id: "concurrent-device",
        resource_uri: RESOURCE,
        token_endpoint_auth_method: "none"
      )
    end

    assert_equal 1, results.count(&:present?)
    assert_equal 1, results.count(&:nil?)
    assert_equal 1, Hitch::AccessToken.count
    winner = results.compact.fetch(0)
    assert Hitch::AccessToken.find_by_token(winner.fetch(:raw_token)).accessible?
  end

  test "a user-code collision inside a host's open transaction retries instead of poisoning it" do
    taken = Hitch::DeviceGrant.mint!(
      client_id: "concurrent-device", scopes: "mcp", resource_uri: RESOURCE
    )
    codes = [ taken.raw_user_code, "3PZT9WKH" ]

    grant = stub_class_method(Hitch::DeviceGrant, :generate_user_code, -> { codes.shift }) do
      # On PostgreSQL a failed INSERT without a savepoint aborts the whole
      # enclosing transaction; the retry then 500s. Only the pair of
      # adapters proves the savepoint.
      ActiveRecord::Base.transaction do
        Hitch::DeviceGrant.mint!(
          client_id: "concurrent-device", scopes: "mcp", resource_uri: RESOURCE
        )
      end
    end

    assert_equal "3PZT9WKH", grant.raw_user_code
    assert Hitch::DeviceGrant.find_pending_by_user_code("3PZT9WKH")
  end

  test "simultaneous approve and deny through independent connections record exactly one decision" do
    grant = Hitch::DeviceGrant.mint!(
      client_id: "concurrent-device", scopes: "mcp", resource_uri: RESOURCE
    )

    results = race(2) do |index|
      if index.zero?
        [ :approve, Hitch::DeviceGrant.approve!(user_code: grant.raw_user_code, principal: @user) ]
      else
        [ :deny, Hitch::DeviceGrant.deny!(user_code: grant.raw_user_code) ]
      end
    end

    decided = results.select { |_, won| won }
    assert_equal 1, decided.length

    row = grant.reload
    assert_nil row.user_code_digest
    if decided.dig(0, 0) == :approve
      assert row.approved_at.present?
      assert_equal @user, row.principal
      assert_nil row.denied_at
    else
      assert row.denied_at.present?
      assert_nil row.approved_at
      assert_nil row.principal_id
    end
  end
end
