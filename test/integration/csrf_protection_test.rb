# frozen_string_literal: true

require "test_helper"
require "securerandom"
require "digest"
require "base64"

# CSRF posture across the gem's endpoints.
#
# A standard Rails host enables forgery protection by default
# (load_defaults >= 5.2 → protect_from_forgery with: :exception). That
# default reaches every controller in the app, including this gem's.
# Two opposite properties must hold under it, and the test suite's global
# `allow_forgery_protection = false` (test.rb) masks both — so these
# tests flip protection ON to exercise the real adopter configuration:
#
#   1. The PUBLIC OAuth endpoints (token / register / revoke) serve
#      non-browser MCP clients that carry no CSRF token. They MUST remain
#      reachable (skip_forgery_protection) — otherwise every adopter with
#      default Rails config gets a 422 on POST /oauth/token and the OAuth
#      flow is dead on arrival.
#   2. The CONSENT POST is session-authenticated and state-changing, so it
#      MUST stay CSRF-protected — a tokenless POST is rejected (422). The
#      rendered consent form carries the token, so real approvals work.
#
# A 422 here is the Rails forgery rejection (InvalidAuthenticityToken,
# rendered as :unprocessable_entity under show_exceptions = :rescuable).
class CsrfProtectionTest < ActionDispatch::IntegrationTest
  HONEST_REDIRECT = "https://claude.ai/callback"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |c|
      c.principal_model = "User"
      c.supported_scopes = [ "mcp" ]
    end
    @victim = User.create!(email: "victim@test")
    @verifier = SecureRandom.urlsafe_base64(64)
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
    @original_forgery = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true # the adopter default
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @original_forgery
  end

  def sign_in(user)
    post "/sign_in", params: { user_id: user.id }
    assert_response :success
  end

  test "public POST /oauth/register stays reachable without a CSRF token" do
    post "/oauth/register", params: { client_name: "Claude", redirect_uris: [ "https://claude.ai/cb" ] }

    refute_equal 422, response.status,
      "CSRF protection blocked a tokenless DCR call — non-browser clients can't register"
    assert_response :created
  end

  test "public POST /oauth/token stays reachable without a CSRF token" do
    # Invalid grant params on purpose — we only care that the request
    # REACHES the controller (a 4xx OAuth error) rather than being
    # rejected at the forgery gate (422).
    post "/oauth/token", params: { grant_type: "authorization_code", code: "nope", code_verifier: "nope" }

    refute_equal 422, response.status,
      "CSRF protection blocked a tokenless token exchange — the OAuth flow can't complete"
    assert_response :bad_request
  end

  test "public POST /oauth/revoke stays reachable without a CSRF token" do
    post "/oauth/revoke", params: { token: "anything" }

    refute_equal 422, response.status,
      "CSRF protection blocked a tokenless revocation"
    assert_response :ok
  end

  test "consent POST /oauth/authorize is CSRF-protected (forged request rejected)" do
    post "/oauth/authorize", params: {
      client_id: "x",
      redirect_uri: "https://claude.ai/cb",
      code_challenge: "c",
      code_challenge_method: "S256"
    } # deliberately no authenticity_token

    assert_response :unprocessable_entity,
      "consent POST accepted a request with no CSRF token — Approve is forgeable"
  end

  # The other half of the property: with forgery protection ON (the
  # adopter default), the LEGITIMATE Approve — submitting the token the
  # rendered consent form carries — must SUCCEED. Without this, "fixing"
  # CSRF could silently break real approvals, and the suite (forgery off
  # globally) would never notice.
  test "consent Approve succeeds with the CSRF token the rendered form carries" do
    post "/oauth/register", params: { client_name: "Claude", redirect_uris: [ HONEST_REDIRECT ] }
    client_id = JSON.parse(response.body)["client_id"]
    sign_in @victim

    authorize_params = {
      client_id: client_id,
      redirect_uri: HONEST_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256"
    }

    get "/oauth/authorize", params: authorize_params
    assert_response :success
    token = css_select("input[name=authenticity_token]").first&.attr("value")
    assert token.present?, "consent form did not render an authenticity_token — real Approve would 422"

    post "/oauth/authorize", params: authorize_params.merge(authenticity_token: token)

    assert_response :redirect, "tokened consent Approve was rejected under forgery protection"
    assert_match(/[?&]code=/, response.location, "Approve did not deliver an authorization code")
  end
end
