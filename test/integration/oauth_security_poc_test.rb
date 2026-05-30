# frozen_string_literal: true

require "test_helper"
require "digest"
require "base64"
require "securerandom"

# Proof-of-concept exploit tests for the two HIGH findings in the
# pre-publication security audit (2026-05-28). These assert the SECURE
# behavior, so they FAIL against the current code (documenting the
# vulnerability) and PASS once the fix lands. Do not delete when fixing
# — they are the regression guard.
class OAuthSecurityPocTest < ActionDispatch::IntegrationTest
  ATTACKER_REDIRECT = "https://attacker.test/cb"
  HONEST_REDIRECT   = "https://claude.ai/callback"
  RESOURCE          = "https://dummy.test/mcp"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |c|
      c.principal_model = "User"
      c.resource_uri = RESOURCE
      c.brand_name = "Dummy"
      c.supported_scopes = [ "mcp" ] # server supports ONLY "mcp"
    end
    @victim = User.create!(email: "victim@test")
    @verifier = SecureRandom.urlsafe_base64(64)
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
  end

  def sign_in(user)
    post "/sign_in", params: { user_id: user.id }
    assert_response :success
  end

  # ───────────────────────────────────────────────────────────────────
  # HIGH-1 — redirect_uri not enforced against client pre-registration.
  #
  # Exploit: an attacker crafts an authorize request with NO client_id
  # and a redirect_uri pointing at a host they control. The victim is
  # signed in and approves (the consent screen can't tell them this is
  # going to an attacker — see HIGH-2 consent blindness). An auth code
  # bound to the VICTIM's principal is delivered to the attacker, who
  # redeems it with their own PKCE verifier → account takeover.
  #
  # check_client_redirect_uri returns nil (skips the check) when
  # client_id is blank, so the only gate is valid_redirect_uri? which
  # passes any https host.
  # ───────────────────────────────────────────────────────────────────
  test "HIGH-1: authorize must reject a request with no registered client_id" do
    sign_in @victim

    post "/oauth/authorize", params: {
      # client_id deliberately omitted — the attacker never registered
      redirect_uri: ATTACKER_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE
    }

    # SECURE: the AS must refuse to mint a code for an unidentified
    # client (OAuth 2.1 §4.1.1 requires client_id; RFC 9700 §2.1
    # requires redirect_uri be matched against pre-registered values).
    refute_equal 302, response.status,
      "VULNERABLE: auth code minted for an unregistered client_id and " \
      "redirected to #{ATTACKER_REDIRECT}. Location: #{response.location}"
    assert_response :bad_request
  end

  test "HIGH-1: even with a known client, redirect must match its registered set" do
    # An honest client registered ONLY its own callback...
    post "/oauth/register", params: { client_name: "Claude", redirect_uris: [ HONEST_REDIRECT ] }
    client = JSON.parse(response.body)
    sign_in @victim

    # ...attacker reuses that client_id but swaps the redirect to their host.
    post "/oauth/authorize", params: {
      client_id: client["client_id"],
      redirect_uri: ATTACKER_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE
    }
    # This path IS covered today (check runs when client_id present) —
    # included so the guard is explicit and survives refactors.
    assert_response :bad_request
  end

  # ───────────────────────────────────────────────────────────────────
  # HIGH-2 — requested scope granted verbatim, not clamped to the
  # server's supported_scopes allowlist.
  #
  # Exploit: client requests scope="admin" (or any string). The server
  # supports only "mcp", but persists "admin" on the token unchanged.
  # The moment any consumer gates on token.has_scope?("admin") — which
  # the gem's own docstring advertises as the pattern — the client has
  # self-elevated. RFC 6749 §3.3 lets the AS narrow scope; granting
  # unknown scopes verbatim is the flaw.
  # ───────────────────────────────────────────────────────────────────
  test "HIGH-2: requested scope must be intersected with supported_scopes" do
    post "/oauth/register", params: { client_name: "Claude", redirect_uris: [ HONEST_REDIRECT ] }
    client = JSON.parse(response.body)
    sign_in @victim

    post "/oauth/authorize", params: {
      client_id: client["client_id"],
      redirect_uri: HONEST_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE,
      scope: "admin" # NOT in supported_scopes
    }
    assert_response :redirect
    code = URI.decode_www_form(URI.parse(response.location).query).to_h["code"]

    post "/oauth/token", params: {
      grant_type: "authorization_code",
      code: code,
      code_verifier: @verifier,
      resource: RESOURCE
    }
    assert_response :success
    granted = JSON.parse(response.body)["scope"]

    # SECURE: the granted scope must NOT contain "admin" — it was never
    # a supported scope. It should be clamped to the "mcp" ∩ requested.
    refute_includes granted.to_s.split(/\s+/), "admin",
      "VULNERABLE: client self-granted scope=#{granted.inspect}; server " \
      "only supports #{Hitch.configuration.supported_scopes.inspect}"
  end

  test "HIGH-2: a requested supported scope is still granted" do
    Hitch.reset_configuration!
    Hitch.configure do |c|
      c.principal_model = "User"
      c.resource_uri = RESOURCE
      c.supported_scopes = [ "mcp", "mcp.write" ]
    end
    post "/oauth/register", params: { client_name: "Claude", redirect_uris: [ HONEST_REDIRECT ] }
    client = JSON.parse(response.body)
    sign_in @victim

    post "/oauth/authorize", params: {
      client_id: client["client_id"], redirect_uri: HONEST_REDIRECT,
      code_challenge: @challenge, code_challenge_method: "S256",
      resource: RESOURCE, scope: "mcp.write evil" # one valid, one not
    }
    code = URI.decode_www_form(URI.parse(response.location).query).to_h["code"]
    post "/oauth/token", params: {
      grant_type: "authorization_code", code: code, code_verifier: @verifier, resource: RESOURCE
    }
    granted = JSON.parse(response.body)["scope"].split(/\s+/)
    # Clamp keeps the supported scope, drops the unsupported one.
    assert_includes granted, "mcp.write"
    refute_includes granted, "evil"
  end

  # ───────────────────────────────────────────────────────────────────
  # L1 — an authorization code is single-use. The fix wraps select +
  # consume in a transaction so the row lock spans the mutation; this
  # asserts the user-visible invariant (a code redeemed twice yields one
  # success, one rejection — never two valid tokens).
  # ───────────────────────────────────────────────────────────────────
  test "L1: an authorization code cannot be redeemed twice" do
    post "/oauth/register", params: { client_name: "Claude", redirect_uris: [ HONEST_REDIRECT ] }
    client = JSON.parse(response.body)
    sign_in @victim
    post "/oauth/authorize", params: {
      client_id: client["client_id"], redirect_uri: HONEST_REDIRECT,
      code_challenge: @challenge, code_challenge_method: "S256", resource: RESOURCE
    }
    code = URI.decode_www_form(URI.parse(response.location).query).to_h["code"]

    post "/oauth/token", params: { grant_type: "authorization_code", code: code, code_verifier: @verifier, resource: RESOURCE }
    assert_response :success

    # Second redemption of the same code must fail.
    post "/oauth/token", params: { grant_type: "authorization_code", code: code, code_verifier: @verifier, resource: RESOURCE }
    assert_response :bad_request
    assert_equal "invalid_grant", JSON.parse(response.body)["error"]
  end
end
