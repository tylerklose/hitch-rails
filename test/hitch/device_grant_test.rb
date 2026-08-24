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
    Hitch.configure { |config| config.device_authorization_enabled = true }
    @user = User.create!(email: "device+#{SecureRandom.hex(4)}@test")
  end

  def mint(client_id: CLIENT_ID, scopes: "mcp", resource_uri: RESOURCE)
    Hitch::DeviceGrant.mint!(client_id: client_id, scopes: scopes, resource_uri: resource_uri)
  end

  def poll(grant, client_id: CLIENT_ID, resource_uri: RESOURCE)
    Hitch::DeviceGrant.exchange_device_code!(
      raw_device_code: grant.raw_device_code,
      client_id: client_id,
      resource_uri: resource_uri
    )
  end

  def poll_error(grant, **options)
    error = assert_raises(Hitch::DeviceGrant::OAuthError) { poll(grant, **options) }
    error.oauth_code
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

  test "a yes given in time is honored by a poll that arrives after expiry" do
    grant = mint
    assert Hitch::DeviceGrant.approve!(user_code: grant.raw_user_code, principal: @user)

    travel_to(grant.reload.expires_at + 3.seconds) do
      assert poll(grant).fetch(:raw_token).present?
    end
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

  test "a deny after approval changes nothing" do
    grant = mint
    assert Hitch::DeviceGrant.approve!(user_code: grant.raw_user_code, principal: @user)

    refute Hitch::DeviceGrant.deny!(user_code: grant.raw_user_code)
    row = grant.reload
    assert row.approved_at.present?
    assert_nil row.denied_at
  end

  test "polling before approval returns authorization_pending" do
    assert_equal "authorization_pending", poll_error(mint)
  end

  test "polling faster than the interval returns slow_down without advancing the window" do
    grant = mint
    started = Time.current

    travel_to(started) { assert_equal "authorization_pending", poll_error(grant) }
    travel_to(started + 2.seconds) { assert_equal "slow_down", poll_error(grant) }
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

  test "a denied grant polls as access_denied even after expiry" do
    grant = mint
    assert Hitch::DeviceGrant.deny!(user_code: grant.raw_user_code)

    travel_to(grant.reload.expires_at + 1.hour) do
      assert_equal "access_denied", poll_error(grant)
    end
  end

  test "an expired grant polls as expired_token" do
    grant = mint
    travel_to(grant.expires_at + 1.second) do
      assert_equal "expired_token", poll_error(grant)
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
    assert_equal "invalid_grant", poll_error(grant, client_id: OTHER_CLIENT_ID)
  end

  test "the poll refuses a mismatched resource" do
    grant = mint
    assert_equal "invalid_target", poll_error(grant, resource_uri: "https://other.test/mcp")
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

    assert_equal "unsupported_grant_type", poll_error(grant)
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
end
