# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "securerandom"

# Rotation and reuse detection. Each protection here is pinned by a test that
# fails when the protection is removed, not by one that merely passes with it
# in place — trap 2 in particular exists because deleting the evidence made
# the alarm disappear without a single test noticing.
class Hitch::RefreshTokenTest < ActiveSupport::TestCase
  CLIENT_ID = "refresh-client"
  OTHER_CLIENT_ID = "someone-elses-client"
  RESOURCE = "https://app.test/mcp"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    @user = User.create!(email: "refresh+#{SecureRandom.hex(4)}@test")
    @verifier = SecureRandom.urlsafe_base64(64)
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
  end

  # A first pair, through the real authorization-code exchange.
  def grant(scopes: "mcp")
    record = Hitch::AccessToken.create_authorization!(
      principal: @user,
      client_id: CLIENT_ID,
      client_name: CLIENT_ID,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource_uri: RESOURCE,
      scopes: scopes
    )
    Hitch::AccessToken.exchange_authorization_code!(
      raw_code: record.raw_authorization_code,
      code_verifier: @verifier,
      client_id: CLIENT_ID,
      resource_uri: RESOURCE
    )
  end

  def refresh(raw_refresh_token, client_id: CLIENT_ID, scopes: nil)
    Hitch::AccessToken.exchange_refresh_token!(
      raw_refresh_token: raw_refresh_token,
      client_id: client_id,
      resource_uri: RESOURCE,
      scopes: scopes
    )
  end

  def row_for(raw_refresh_token)
    Hitch::AccessToken.find_by_refresh_token(raw_refresh_token)
  end

  test "the code exchange issues a refresh token bound to a new family" do
    result = grant

    row = row_for(result.fetch(:raw_refresh_token))
    assert_not_nil result[:raw_refresh_token]
    assert_not_nil row.family_id
    assert_nil row.refresh_consumed_at
    # No absolute ceiling by default: a person using the app is never cut off
    # by a clock they cannot see.
    assert_nil row.family_expires_at
  end

  # The whole point of the default. Five months of ordinary use, each refresh
  # comfortably inside the idle window: nothing interrupts the person. A
  # 90-day ceiling would cut this off partway through, which is the
  # disconnection this feature exists to remove arriving on a timer.
  test "a family still refreshes after longer than a ceiling would have allowed" do
    result = grant
    started_at = Time.current

    6.times do |index|
      travel_to(started_at + ((index + 1) * 25).days) do
        result = refresh(result.fetch(:raw_refresh_token))
        assert_not_nil result, "disconnected after #{(index + 1) * 25} days of use"
      end
    end

    assert_nil row_for(result.fetch(:raw_refresh_token)).family_expires_at
  end

  test "an operator who configures a ceiling gets one, clamped into every successor" do
    Hitch.configuration.refresh_token_family_lifetime_seconds = 3 * 86_400
    first = grant

    second = refresh(first.fetch(:raw_refresh_token))

    parent = row_for(first.fetch(:raw_refresh_token))
    child = row_for(second.fetch(:raw_refresh_token))
    assert_not_nil parent.family_expires_at
    # The idle window is 30 days and the ceiling 3; the clamp is what stops a
    # token outliving the family it belongs to.
    assert_operator child.refresh_expires_at, :<=, child.family_expires_at
    assert_equal parent.family_expires_at.to_i, child.family_expires_at.to_i
  end

  test "rotation consumes the presented token and issues a successor in the same family" do
    first = grant

    second = refresh(first.fetch(:raw_refresh_token))

    parent = row_for(first.fetch(:raw_refresh_token))
    child = row_for(second.fetch(:raw_refresh_token))
    assert_not_equal first.fetch(:raw_refresh_token), second.fetch(:raw_refresh_token)
    assert_not_equal first.fetch(:raw_token), second.fetch(:raw_token)
    assert_not_nil parent.refresh_consumed_at
    assert_equal parent.family_id, child.family_id
    # A family's terms are inherited, including the usual absence of a ceiling.
    assert_nil child.family_expires_at
    assert_equal child.id, Hitch::AccessToken.find_by_token(second.fetch(:raw_token)).id
  end

  # Trap 1. Remove the grace window and this is a logged-out user with a
  # theft alarm, for a dropped response.
  test "an honest retry inside the grace window returns a fresh pair, not a revoked family" do
    first = grant
    refresh(first.fetch(:raw_refresh_token))

    retried = refresh(first.fetch(:raw_refresh_token))

    assert_not_nil retried
    assert_equal row_for(first.fetch(:raw_refresh_token)).family_id,
      row_for(retried.fetch(:raw_refresh_token)).family_id
    refute Hitch::AccessToken.where(family_id: row_for(retried.fetch(:raw_refresh_token)).family_id)
      .where.not(revoked_at: nil).exists?
  end

  test "strict one-time-use is available by setting the grace window to zero" do
    Hitch.configuration.refresh_token_replay_grace_seconds = 0
    first = grant
    refresh(first.fetch(:raw_refresh_token))

    assert_raises(Hitch::AccessToken::OAuthError) { refresh(first.fetch(:raw_refresh_token)) }
    assert_family_revoked(first)
  end

  test "a replay past the grace window revokes every token in the family" do
    first = grant
    second = refresh(first.fetch(:raw_refresh_token))
    age_past_grace(first)

    error = assert_raises(Hitch::AccessToken::OAuthError) { refresh(first.fetch(:raw_refresh_token)) }

    assert_equal "invalid_grant", error.oauth_code
    assert_family_revoked(first)
    # The successor's access token dies with the family; revoking one link
    # while the rest of the chain still opens /mcp would be no revocation.
    assert_nil Hitch::AccessToken.find_by_token(second.fetch(:raw_token))
  end

  # Trap 3. A different client_id is a mismatched grant, not a theft alarm —
  # otherwise anyone who learns a token can log its owner out.
  test "the wrong client is refused without revoking anything" do
    first = grant
    refresh(first.fetch(:raw_refresh_token))
    age_past_grace(first)

    error = assert_raises(Hitch::AccessToken::OAuthError) do
      refresh(first.fetch(:raw_refresh_token), client_id: OTHER_CLIENT_ID)
    end

    assert_equal "invalid_grant", error.oauth_code
    assert_family_live(first)
  end

  test "an unconsumed token presented by the wrong client is refused without revoking" do
    first = grant

    assert_raises(Hitch::AccessToken::OAuthError) do
      refresh(first.fetch(:raw_refresh_token), client_id: OTHER_CLIENT_ID)
    end
    assert_family_live(first)
    # Still usable by its actual owner.
    assert_not_nil refresh(first.fetch(:raw_refresh_token))
  end

  # Trap 4. find_by_token reads token_digest only; a refresh token must never
  # satisfy it.
  test "a refresh token is not an access token" do
    first = grant

    assert_nil Hitch::AccessToken.find_by_token(first.fetch(:raw_refresh_token))
    assert_not_nil Hitch::AccessToken.find_by_token(first.fetch(:raw_token))
  end

  # Trap 2. The evidence a replay is measured against is a consumed row, and
  # expires_at is the ACCESS token's one-hour clock.
  test "cleanup keeps consumed evidence while the family is still live" do
    first = grant
    refresh(first.fetch(:raw_refresh_token))
    age_past_grace(first)
    # Its own refresh window is past, so the usable-token floor cannot be what
    # saves this row — a client that refreshed late in the window leaves
    # exactly this shape, and only the evidence floor stands between it and
    # a silently missing alarm.
    row_for(first.fetch(:raw_refresh_token))
      .update_columns(expires_at: 60.days.ago, refresh_expires_at: 1.day.ago)

    Hitch::AccessToken.cleanup_expired!(revoked_retention_days: 30)

    assert_not_nil row_for(first.fetch(:raw_refresh_token))
    assert_raises(Hitch::AccessToken::OAuthError) { refresh(first.fetch(:raw_refresh_token)) }
    assert_family_revoked(first)
  end

  # The other half of that guard: it defers collection, it does not cancel
  # it. With no ceiling a family can rotate forever, so a floor that never
  # released would be unbounded growth arriving through the back door.
  test "cleanup collects the same rows once the evidence is past the window" do
    first = grant
    refresh(first.fetch(:raw_refresh_token))
    family_id = row_for(first.fetch(:raw_refresh_token)).family_id
    Hitch::AccessToken.where(family_id: family_id).update_all(
      expires_at: 60.days.ago, refresh_expires_at: 40.days.ago, refresh_consumed_at: 40.days.ago
    )

    Hitch::AccessToken.cleanup_expired!(revoked_retention_days: 30)

    assert_equal 0, Hitch::AccessToken.where(family_id: family_id).count
  end

  # The other floor. A row whose access token lapsed weeks ago may still hold
  # the refresh token the client is about to present.
  test "cleanup keeps a row that still holds a usable refresh token" do
    first = grant
    row_for(first.fetch(:raw_refresh_token)).update_columns(expires_at: 60.days.ago)

    Hitch::AccessToken.cleanup_expired!(revoked_retention_days: 30)

    assert_not_nil row_for(first.fetch(:raw_refresh_token))
    assert_not_nil refresh(first.fetch(:raw_refresh_token))
  end

  test "a refresh may narrow scopes and may never widen them" do
    first = grant(scopes: "mcp")

    narrowed = refresh(first.fetch(:raw_refresh_token), scopes: "mcp")
    assert_equal "mcp", narrowed.fetch(:scope)

    error = assert_raises(Hitch::AccessToken::OAuthError) do
      refresh(narrowed.fetch(:raw_refresh_token), scopes: "mcp admin")
    end
    assert_equal "invalid_scope", error.oauth_code
  end

  test "concurrent refreshes of one token produce one successor, not two families" do
    first = grant
    raw = first.fetch(:raw_refresh_token)
    now = Time.current
    row = row_for(raw)

    # The conditional update is the whole concurrency story: simulate the
    # loser by spending the row out from under a second attempt.
    Hitch::AccessToken.where(id: row.id, refresh_consumed_at: nil)
      .update_all(refresh_consumed_at: now, updated_at: now)
    loser = Hitch::AccessToken.where(id: row.id, refresh_consumed_at: nil)
      .update_all(refresh_consumed_at: now, updated_at: now)

    assert_equal 0, loser
    # And the loser's request is an honest retry, not a theft alarm.
    assert_not_nil refresh(raw)
    assert_family_live(first)
  end

  test "a configured family ceiling stops a chain that is still being rotated" do
    first = grant
    row = row_for(first.fetch(:raw_refresh_token))
    row.update_columns(family_expires_at: 1.second.ago)

    assert_nil refresh(first.fetch(:raw_refresh_token))
  end

  test "the flag closes the grant entirely" do
    first = grant
    Hitch.configuration.refresh_tokens_enabled = false

    error = assert_raises(Hitch::AccessToken::OAuthError) { refresh(first.fetch(:raw_refresh_token)) }

    assert_equal "unsupported_grant_type", error.oauth_code
    assert_equal [ "authorization_code" ], Hitch::GrantTypes.supported
  end

  test "with the flag off the code exchange issues no refresh token at all" do
    Hitch.configuration.refresh_tokens_enabled = false

    result = grant

    assert_nil result[:raw_refresh_token]
    assert_nil Hitch::AccessToken.find_by_token(result.fetch(:raw_token)).refresh_token_digest
  end

  private

  def age_past_grace(result)
    row = row_for(result.fetch(:raw_refresh_token))
    grace = Hitch.configuration.refresh_token_replay_grace_seconds
    row.update_columns(refresh_consumed_at: (grace + 60).seconds.ago)
  end

  def assert_family_revoked(result)
    family_id = row_for(result.fetch(:raw_refresh_token)).family_id
    assert_equal 0, Hitch::AccessToken.where(family_id: family_id, revoked_at: nil).count
  end

  def assert_family_live(result)
    family_id = row_for(result.fetch(:raw_refresh_token)).family_id
    assert_equal 0, Hitch::AccessToken.where(family_id: family_id).where.not(revoked_at: nil).count
  end
end
