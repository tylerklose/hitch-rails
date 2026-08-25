# frozen_string_literal: true

require "test_helper"
require "digest"
require "securerandom"

# The device grant state machine (RFC 8628). Each single-use transition here
# is pinned the way the code exchange's is: the guard lives in one UPDATE's
# WHERE clause, and these tests fail when a guard is removed, not merely pass
# while it is in place.
class Hitch::DeviceGrantTest < ActiveSupport::TestCase
  CLIENT_ID = "device-client"
  OTHER_CLIENT_ID = "someone-elses-client"
  RESOURCE = "https://app.test/mcp"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::DeviceGrant.delete_all
    Hitch::Client.delete_all
    Hitch.configure { |config| config.device_authorization_enabled = true }
    @user = User.create!(email: "device+#{SecureRandom.hex(4)}@test")
  end

  def mint(client_id: CLIENT_ID, scopes: "mcp", resource_uri: RESOURCE)
    Hitch::DeviceGrant.mint!(client_id: client_id, scopes: scopes, resource_uri: resource_uri)
  end

  def poll(grant, client_id: CLIENT_ID, resource_uri: RESOURCE, token_endpoint_auth_method: "none")
    Hitch::DeviceGrant.exchange_device_code!(
      raw_device_code: grant.raw_device_code,
      client_id: client_id,
      resource_uri: resource_uri,
      token_endpoint_auth_method: token_endpoint_auth_method
    )
  end

  def poll_error(grant, **options)
    poll_exception(grant, **options).oauth_code
  end

  def poll_exception(grant, **options)
    assert_raises(Hitch::DeviceGrant::OAuthError) { poll(grant, **options) }
  end

  test "mint stores only digests and returns the raw codes once" do
    grant = mint

    assert_equal Hitch::DeviceGrant::USER_CODE_LENGTH, grant.raw_user_code.length
    assert grant.raw_user_code.chars.all? { |c| Hitch::DeviceGrant::USER_CODE_ALPHABET.include?(c) }
    assert_equal Digest::SHA256.hexdigest(grant.raw_device_code), grant.device_code_digest
    assert_equal Digest::SHA256.hexdigest(grant.raw_user_code), grant.user_code_digest
    row = grant.reload
    refute_includes row.attributes.values, grant.raw_device_code
    refute_includes row.attributes.values, grant.raw_user_code
  end

  test "mint clamps scopes to what the host supports, whoever calls it" do
    grant = mint(scopes: "mcp payments:write")

    assert_equal "mcp", grant.scopes
    assert_equal "mcp", mint(scopes: "").scopes
  end

  test "an approved device code cannot be redeemed after expiry" do
    grant = mint
    assert Hitch::DeviceGrant.approve!(user_code: grant.raw_user_code, principal: @user)

    travel_to(grant.reload.expires_at + 3.seconds) do
      assert_equal "expired_token", poll_error(grant)
      assert_nil grant.reload.consumed_at
      assert_empty Hitch::AccessToken.where(client_id: CLIENT_ID)
    end
  end

  test "an approved device code expires at the exact advertised instant" do
    grant = mint
    assert Hitch::DeviceGrant.approve!(user_code: grant.raw_user_code, principal: @user)

    travel_to(grant.reload.expires_at, with_usec: true) do
      error = poll_exception(grant)
      assert_equal "expired_token", error.oauth_code
      assert_equal "Device code expired", error.description
    end
  end

  test "mint records the token endpoint authentication posture" do
    credentials = Hitch::Client.register_confidential!(
      client_id: "operator-device-client",
      client_name: "Operator Device Client",
      redirect_uris: [ "https://agent.example/callback" ],
      operator_registered: true
    )

    assert_equal "client_secret_basic", mint(client_id: credentials.client.client_id).token_endpoint_auth_method
    assert_equal "none", mint(client_id: "public-device-client").token_endpoint_auth_method
  end

  test "the poll grace scales down so it can never halve a short interval" do
    Hitch.configuration.device_authorization_interval_seconds = 1
    grant = mint
    started = Time.current

    travel_to(started, with_usec: true) { assert_equal "authorization_pending", poll_error(grant) }
    travel_to(started + 0.5.seconds, with_usec: true) { assert_equal "slow_down", poll_error(grant) }
    travel_to(started + 0.95.seconds, with_usec: true) do
      assert_equal "authorization_pending", poll_error(grant)
    end
  end

  test "mint retries a colliding user code instead of failing" do
    taken = mint
    codes = [ taken.raw_user_code, taken.raw_user_code, "3PZT9WKH" ]
    grant = stub_class_method(Hitch::DeviceGrant, :generate_user_code, -> { codes.shift }) do
      mint
    end

    assert_equal "3PZT9WKH", grant.raw_user_code
    assert Hitch::DeviceGrant.find_pending_by_user_code("3PZT9WKH")
  end

  test "verification normalizes case, hyphens, and confusable characters before comparing" do
    grant = mint
    sloppy = Hitch::DeviceGrant.display_user_code(grant.raw_user_code)
      .downcase.tr("01", "ol")

    assert_equal grant.id, Hitch::DeviceGrant.find_pending_by_user_code(sloppy)&.id
  end

  test "an expired or spent code never verifies" do
    expired = mint
    travel_to(expired.expires_at + 1.second) do
      assert_nil Hitch::DeviceGrant.find_pending_by_user_code(expired.raw_user_code)
    end

    spent = mint
    assert Hitch::DeviceGrant.approve!(user_code: spent.raw_user_code, principal: @user)
    assert_nil Hitch::DeviceGrant.find_pending_by_user_code(spent.raw_user_code)
  end

  test "approval binds the signed-in principal in the same statement that decides" do
    grant = mint

    assert Hitch::DeviceGrant.approve!(
      user_code: grant.raw_user_code, principal: @user, client_name: "Claude"
    )

    row = grant.reload
    assert row.approved_at.present?
    assert_equal @user, row.principal
    assert_equal "Claude", row.client_name
    assert_nil row.user_code_digest
  end

  test "approval refuses an unpersisted principal without deciding the grant" do
    grant = mint

    error = assert_raises(ArgumentError) do
      Hitch::DeviceGrant.approve!(
        user_code: grant.raw_user_code,
        principal: User.new(email: "not-saved@test")
      )
    end

    assert_equal "principal must be persisted", error.message
    row = grant.reload
    assert_nil row.approved_at
    assert row.user_code_digest.present?
  end

  test "database constraints reject conflicting or ownerless grant states" do
    ownerless = mint
    assert_database_rejects do
      ownerless.update_columns(approved_at: Time.current)
    end

    conflicting = mint
    assert_database_rejects do
      conflicting.update_columns(
        approved_at: Time.current,
        denied_at: Time.current,
        principal_type: @user.class.polymorphic_name,
        principal_id: @user.id
      )
    end

    consumed_without_approval = mint
    assert_database_rejects do
      consumed_without_approval.update_columns(consumed_at: Time.current)
    end
  end

  test "a deny after approval changes nothing" do
    grant = mint
    assert Hitch::DeviceGrant.approve!(user_code: grant.raw_user_code, principal: @user)

    refute Hitch::DeviceGrant.deny!(user_code: grant.raw_user_code)
    row = grant.reload
    assert row.approved_at.present?
    assert_nil row.denied_at
  end

  test "polling before approval returns authorization_pending" do
    error = poll_exception(mint)
    assert_equal "authorization_pending", error.oauth_code
    assert_equal "The authorization request is still pending", error.description
  end

  test "polling faster than the interval returns slow_down without advancing the window" do
    grant = mint
    started = Time.current

    travel_to(started) { assert_equal "authorization_pending", poll_error(grant) }
    travel_to(started + 2.seconds) do
      error = poll_exception(grant)
      assert_equal "slow_down", error.oauth_code
      assert_equal "Polling faster than the interval", error.description
    end
    # A rejected poll wrote nothing, so this lands a full interval after the
    # CLAIMED poll and gets through — hammering throttles to the interval,
    # it does not lock out.
    travel_to(started + 6.seconds) { assert_equal "authorization_pending", poll_error(grant) }
  end

  test "a conformant poller's jitter does not cost it a slow_down" do
    grant = mint
    started = Time.current

    # with_usec: travel_to otherwise floors to the second, and these
    # windows are sub-second.
    travel_to(started, with_usec: true) { assert_equal "authorization_pending", poll_error(grant) }
    # 4.6s after a 5s-interval claim: inside the half-second grace, so a
    # fixed-rate ticker's network jitter is not punished into the
    # permanent +5s a slow_down demands.
    travel_to(started + 4.6.seconds, with_usec: true) do
      assert_equal "authorization_pending", poll_error(grant)
    end
  end

  test "poll grace is capped at half a second for long intervals" do
    Hitch.configuration.device_authorization_interval_seconds = 10
    grant = mint
    started = Time.current

    travel_to(started, with_usec: true) { assert_equal "authorization_pending", poll_error(grant) }
    travel_to(started + 9.2.seconds, with_usec: true) do
      assert_equal "slow_down", poll_error(grant)
    end
    travel_to(started + 9.6.seconds, with_usec: true) do
      assert_equal "authorization_pending", poll_error(grant)
    end
  end

  test "polling one grant claims only its own window and updates its timestamp" do
    grant = mint
    untouched = mint
    previous_updated_at = grant.updated_at

    travel_to(Time.current + 1.second, with_usec: true) do
      assert_equal "authorization_pending", poll_error(grant)
    end

    assert grant.reload.last_polled_at.present?
    assert_operator grant.updated_at, :>, previous_updated_at
    assert_nil untouched.reload.last_polled_at
  end

  test "a denied grant polls as access_denied even after expiry" do
    grant = mint
    assert Hitch::DeviceGrant.deny!(user_code: grant.raw_user_code)

    travel_to(grant.reload.expires_at + 1.hour) do
      error = poll_exception(grant)
      assert_equal "access_denied", error.oauth_code
      assert_equal "The request was denied", error.description
    end
  end

  test "an expired grant polls as expired_token" do
    grant = mint
    travel_to(grant.expires_at + 1.second) do
      error = poll_exception(grant)
      assert_equal "expired_token", error.oauth_code
      assert_equal "Device code expired", error.description
    end
  end

  test "consumption issues the token through the real exchange path with the scopes granted at mint" do
    grant = mint(scopes: "mcp")
    assert Hitch::DeviceGrant.approve!(
      user_code: grant.raw_user_code, principal: @user, client_name: "Claude"
    )

    result = poll(grant)

    assert_equal "mcp", result.fetch(:scope)
    assert result.fetch(:raw_refresh_token).present?
    token = Hitch::AccessToken.find_by_token(result.fetch(:raw_token))
    assert token.accessible?
    assert_equal @user, token.principal
    assert_equal CLIENT_ID, token.client_id
    assert_equal RESOURCE, token.resource_uri
    assert grant.reload.consumed_at.present?
  end

  test "a consumed device code polls as invalid_grant" do
    grant = mint
    assert Hitch::DeviceGrant.approve!(user_code: grant.raw_user_code, principal: @user)
    assert poll(grant)

    assert_nil poll(grant)
  end

  test "the poll refuses a device code issued to a different client" do
    grant = mint
    error = poll_exception(grant, client_id: OTHER_CLIENT_ID)
    assert_equal "invalid_grant", error.oauth_code
    assert_equal "Device code was not issued to this client", error.description
  end

  test "the poll refuses a mismatched resource" do
    grant = mint
    error = poll_exception(grant, resource_uri: "https://other.test/mcp")
    assert_equal "invalid_target", error.oauth_code
    assert_equal "resource does not match the authorized resource", error.description
  end

  test "the poll refuses a different token endpoint authentication method" do
    grant = Hitch::DeviceGrant.mint!(
      client_id: CLIENT_ID,
      scopes: "mcp",
      resource_uri: RESOURCE,
      token_endpoint_auth_method: "client_secret_basic"
    )

    error = assert_raises(Hitch::ClientAuthentication::Invalid) { poll(grant) }
    assert_equal "invalid_client", error.oauth_code
    assert_equal "Client authentication failed", error.message
    assert_equal :unauthorized, error.http_status
  end

  test "a refresh flag flipped after approval is honored at consumption" do
    grant = mint
    assert Hitch::DeviceGrant.approve!(user_code: grant.raw_user_code, principal: @user)
    Hitch.configuration.refresh_tokens_enabled = false

    result = poll(grant)

    assert result.fetch(:raw_token).present?
    assert_nil result[:raw_refresh_token]
  end

  test "an approver deleted before the poll kills the grant, not the server" do
    grant = mint
    assert Hitch::DeviceGrant.approve!(user_code: grant.raw_user_code, principal: @user)
    @user.destroy!

    assert_nil poll(grant)
  end

  test "the disabled feature refuses the grant at the model" do
    grant = mint
    Hitch.configuration.device_authorization_enabled = false

    error = poll_exception(grant)
    assert_equal "unsupported_grant_type", error.oauth_code
    assert_equal "Device authorization is not enabled", error.description
  end

  test "a nil device code is an ordinary invalid grant" do
    assert_nil Hitch::DeviceGrant.exchange_device_code!(
      raw_device_code: nil,
      client_id: CLIENT_ID,
      resource_uri: RESOURCE,
      token_endpoint_auth_method: "none"
    )
  end

  test "cleanup holds every row a day past expiry so wire answers don't depend on job timing" do
    live = mint
    freshly_expired = mint
    freshly_expired.update_columns(expires_at: 1.minute.ago)
    old = mint
    old.update_columns(expires_at: 25.hours.ago)

    assert_equal 1, Hitch::DeviceGrant.cleanup_expired!
    assert Hitch::DeviceGrant.exists?(live.id)
    assert Hitch::DeviceGrant.exists?(freshly_expired.id)
    refute Hitch::DeviceGrant.exists?(old.id)
    # The held row still answers §3.5 truthfully.
    assert_equal "expired_token", poll_error(freshly_expired)
  end

  test "cleanup holds a denied grant so the no keeps answering access_denied" do
    grant = mint
    assert Hitch::DeviceGrant.deny!(user_code: grant.raw_user_code)
    grant.update_columns(expires_at: 1.hour.ago)

    assert_equal 0, Hitch::DeviceGrant.cleanup_expired!
    assert_equal "access_denied", poll_error(grant)

    travel_to(25.hours.from_now) do
      assert_equal 1, Hitch::DeviceGrant.cleanup_expired!
    end
    refute Hitch::DeviceGrant.exists?(grant.id)
  end

  private

  def assert_database_rejects(&block)
    assert_raises(ActiveRecord::StatementInvalid) do
      Hitch::DeviceGrant.transaction(requires_new: true, &block)
    end
  end
end
