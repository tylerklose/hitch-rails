# frozen_string_literal: true

require "test_helper"
require "digest"
require "base64"
require "securerandom"

# Scenarios in test/lattice/access_token_scenarios.json are the source of
# truth. Each test below pins one row's intended behavior against the
# substrate. If lattice regenerates with more rows, add tests; do not
# silently let an uncovered row land.
class Hitch::AccessTokenTest < ActiveSupport::TestCase
  CLIENT_ID = "client-test"
  CLIENT_NAME = "Test Client"
  RESOURCE_A = "https://app.test/mcp"
  RESOURCE_B = "https://other.test/mcp"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    @user = User.create!(email: "row+#{SecureRandom.hex(4)}@test")
    @verifier = SecureRandom.urlsafe_base64(64)
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
  end

  def mint(resource: RESOURCE_A)
    Hitch::AccessToken.create_authorization!(
      principal: @user,
      client_id: CLIENT_ID,
      client_name: CLIENT_NAME,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource_uri: resource
    )
  end

  # Row 1: happy path
  test "fresh code + correct verifier + matching resource → token usable" do
    record = mint(resource: RESOURCE_A)
    raw_token = record.consume_code!(@verifier)

    assert record.accessible?
    assert record.valid_for_resource?(RESOURCE_A)
    assert_equal record.id, Hitch::AccessToken.find_by_token(raw_token).id
  end

  # Row 2: PKCE mismatch
  test "fresh code + wrong verifier → consume_code! raises invalid_grant" do
    record = mint
    err = assert_raises(Hitch::AccessToken::OAuthError) do
      record.consume_code!("not-the-real-verifier")
    end
    assert_equal "invalid_grant", err.oauth_code
    assert_match(/PKCE/, err.description)
    assert_nil record.reload.token_digest
  end

  # Row 3: expired auth code
  test "expired code + correct verifier → consume_code! raises invalid_grant" do
    record = mint
    record.update_columns(code_expires_at: 1.minute.ago)
    err = assert_raises(Hitch::AccessToken::OAuthError) do
      record.consume_code!(@verifier)
    end
    assert_equal "invalid_grant", err.oauth_code
    assert_match(/expired/i, err.description)
  end

  # Row 4: RFC 8707 audience mismatch
  test "active token + different resource at check → valid_for_resource? false" do
    record = mint(resource: RESOURCE_A)
    record.consume_code!(@verifier)
    refute record.valid_for_resource?(RESOURCE_B)
  end

  # Row 5: revoked
  test "revoked token → not accessible, not findable" do
    record = mint
    raw_token = record.consume_code!(@verifier)
    record.revoke!
    refute record.reload.accessible?
    assert_nil Hitch::AccessToken.find_by_token(raw_token)
  end

  # Row 6: token issued without audience, no resource at check
  test "no resource at issue, no resource at check → valid_for_resource? false (blank resource)" do
    record = mint(resource: nil)
    record.consume_code!(@verifier)
    refute record.valid_for_resource?(nil)
    refute record.valid_for_resource?("")
  end

  # Row 7: expired + wrong (defense in depth — either alone blocks)
  test "expired code + wrong verifier → invalid_grant on expiry check first" do
    record = mint(resource: nil)
    record.update_columns(code_expires_at: 1.minute.ago)
    err = assert_raises(Hitch::AccessToken::OAuthError) do
      record.consume_code!("not-the-real-verifier")
    end
    assert_equal "invalid_grant", err.oauth_code
  end

  # Row 8: re-consume on revoked token
  test "second consume_code! on already-consumed token raises (code is nil)" do
    record = mint(resource: nil)
    record.consume_code!(@verifier)
    record.revoke!

    # code_expires_at was cleared on first consume; second call should raise
    # because verify_pkce! sees code_expires_at: nil → "expired" branch.
    err = assert_raises(Hitch::AccessToken::OAuthError) do
      record.consume_code!(@verifier)
    end
    assert_equal "invalid_grant", err.oauth_code
  end

  # Row 9: idempotency — token exists with audience matching
  test "consumed + active + audience matches → still valid even if consume tried again" do
    record = mint(resource: RESOURCE_A)
    record.consume_code!(@verifier)
    assert record.valid_for_resource?(RESOURCE_A)

    # Second consume must fail (code is gone)
    assert_raises(Hitch::AccessToken::OAuthError) { record.consume_code!(@verifier) }
    # Token is unaffected
    assert record.reload.accessible?
  end

  # Row 10: revoked + audience set + check blank
  test "revoked token with audience set, asked with blank → not valid_for_resource" do
    record = mint(resource: RESOURCE_A)
    record.consume_code!(@verifier)
    record.revoke!
    refute record.valid_for_resource?("")
    refute record.accessible?
  end

  # Row 11: audience absent at issue, ask with a real resource
  test "token issued without audience → valid_for_resource? false for any concrete resource" do
    record = mint(resource: nil)
    record.consume_code!(@verifier)
    refute record.valid_for_resource?(RESOURCE_A)
  end

  # Substrate invariants outside the lattice matrix:

  test "authorization_code is hashed: DB stores SHA256, raw returned via attr_accessor" do
    record = mint
    assert record.raw_authorization_code.present?, "raw code should be exposed on create"
    assert_equal Digest::SHA256.hexdigest(record.raw_authorization_code), record.authorization_code_digest
    refute_equal record.raw_authorization_code, record.authorization_code_digest

    # Reloading drops the transient raw value — only the digest is in the DB
    reloaded = Hitch::AccessToken.find(record.id)
    assert_nil reloaded.raw_authorization_code
    assert reloaded.authorization_code_digest.present?
  end

  test "find_pending_by_code hashes inbound + finds the row" do
    record = mint
    raw = record.raw_authorization_code

    assert_equal record.id, Hitch::AccessToken.find_pending_by_code(raw).id
    assert_nil Hitch::AccessToken.find_pending_by_code("wrong-code")
    assert_nil Hitch::AccessToken.find_pending_by_code(nil)
    assert_nil Hitch::AccessToken.find_pending_by_code("")
  end

  test "token_digest is SHA256 of raw token, not the raw token itself" do
    record = mint
    raw_token = record.consume_code!(@verifier)
    refute_equal raw_token, record.token_digest
    assert_equal Digest::SHA256.hexdigest(raw_token), record.token_digest
  end

  test "principal is polymorphic — User reaches its tokens via has_many" do
    record = mint
    record.consume_code!(@verifier)
    assert_includes @user.reload.access_tokens, record
  end

  test "pending scope filters to records with no token_digest + unexpired code" do
    pending = mint
    consumed = mint
    consumed.consume_code!(@verifier)

    pending_ids = Hitch::AccessToken.pending.pluck(:id)
    assert_includes pending_ids, pending.id
    refute_includes pending_ids, consumed.id
  end

  test "active scope filters out revoked + expired" do
    revoked = mint
    revoked.consume_code!(@verifier)
    revoked.revoke!

    active = mint
    active.consume_code!(@verifier)

    active_ids = Hitch::AccessToken.active.pluck(:id)
    assert_includes active_ids, active.id
    refute_includes active_ids, revoked.id
  end

  test "has_scope? matches space-delimited scope values" do
    record = mint
    record.update!(scopes: "read write mcp")

    assert record.has_scope?("read")
    assert record.has_scope?("write")
    assert record.has_scope?("mcp")
    refute record.has_scope?("admin")
    refute record.has_scope?("rea")
    refute record.has_scope?(nil)
    refute record.has_scope?("")
  end

  test "has_scope? handles single-scope rows" do
    record = mint
    record.update!(scopes: "mcp")
    assert record.has_scope?("mcp")
    refute record.has_scope?("write")
  end

  test "cleanup_expired! drops orphaned pending codes" do
    fresh_pending = mint
    expired_pending = mint
    expired_pending.update_column(:code_expires_at, 1.minute.ago)

    deleted = Hitch::AccessToken.cleanup_expired!

    assert deleted >= 1
    assert Hitch::AccessToken.exists?(fresh_pending.id), "fresh pending must survive"
    refute Hitch::AccessToken.exists?(expired_pending.id), "expired pending must be dropped"
  end

  test "cleanup_expired! keeps revoked tokens inside retention window" do
    record = mint
    record.consume_code!(@verifier)
    record.update!(revoked_at: 5.days.ago)

    Hitch::AccessToken.cleanup_expired!(revoked_retention_days: 30)

    assert Hitch::AccessToken.exists?(record.id), "revoked-but-recent must survive"
  end

  test "cleanup_expired! drops revoked tokens older than retention" do
    record = mint
    record.consume_code!(@verifier)
    record.update!(revoked_at: 60.days.ago)

    Hitch::AccessToken.cleanup_expired!(revoked_retention_days: 30)

    refute Hitch::AccessToken.exists?(record.id)
  end

  test "cleanup_expired! drops expired tokens older than retention" do
    record = mint
    record.consume_code!(@verifier)
    # Bypass the cant-set-past-expires guard by direct column update
    record.update_columns(expires_at: 60.days.ago)

    Hitch::AccessToken.cleanup_expired!(revoked_retention_days: 30)

    refute Hitch::AccessToken.exists?(record.id)
  end

  test "cleanup_expired! leaves active tokens untouched" do
    record = mint
    record.consume_code!(@verifier)
    assert record.accessible?

    Hitch::AccessToken.cleanup_expired!

    assert Hitch::AccessToken.exists?(record.id)
  end
end
