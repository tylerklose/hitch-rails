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
#      MUST stay CSRF-protected — a forged POST is rejected (422) and a
#      real browser Approve succeeds. WHICH credential proves a request
#      genuine depends on the host's Rails:
#
#        - Through 8.1: the authenticity token the consent form renders.
#        - load_defaults 8.2: the browser's Sec-Fetch-Site header
#          (forgery_protection_verification_strategy = :header_only) —
#          the rendered token is never consulted.
#
#      A real browser sends both, so Approve works either way.
#
# A 422 here is the Rails forgery rejection (InvalidAuthenticityToken;
# InvalidCrossOriginRequest from 8.2 — rendered as :unprocessable_entity
# under show_exceptions = :rescuable).
class CsrfProtectionTest < ActionDispatch::IntegrationTest
  HONEST_REDIRECT = "https://claude.ai/callback"

  # Browsers attach Sec-Fetch-Site to every request they originate, and a
  # page cannot forge it (forbidden header name). "same-origin" is what a
  # submit of the rendered consent form carries.
  BROWSER_SAME_ORIGIN = { "Sec-Fetch-Site" => "same-origin" }.freeze

  # Which credential the consent controller consults (property 2 above).
  # If a lane ever runs a third strategy (:header_or_legacy_token), the
  # mechanism test below goes red — state the property for it then.
  HEADER_VERIFIED =
    Hitch::AuthorizationsController.respond_to?(:forgery_protection_verification_strategy) &&
      Hitch::AuthorizationsController.forgery_protection_verification_strategy == :header_only

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |c|
      c.resource_uri = "https://dummy.test/mcp"
      c.allowed_hosts = [ "www.example.com" ]
      c.allowed_origins = [ "https://claude.ai" ]
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
    post "/oauth/register", params: { client_name: "Claude", redirect_uris: [ "https://claude.ai/cb" ] }, as: :json

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
    forged_params = {
      response_type: "code",
      client_id: "x",
      redirect_uri: "https://claude.ai/cb",
      code_challenge: "c",
      code_challenge_method: "S256"
    } # deliberately no authenticity_token

    # A non-browser forger: no token, no browser header.
    post "/oauth/authorize", params: forged_params
    assert_response :unprocessable_entity,
      "consent POST accepted a request with no CSRF credential — Approve is forgeable"

    # A browser-mounted CSRF attack: the victim's browser labels it cross-site.
    post "/oauth/authorize", params: forged_params, headers: { "Sec-Fetch-Site" => "cross-site" }
    assert_response :unprocessable_entity,
      "consent POST accepted a cross-site browser request — Approve is forgeable"
  end

  # The other half of the property: with forgery protection ON (the
  # adopter default), the LEGITIMATE Approve must SUCCEED. A real browser
  # submits the rendered form with the authenticity token in the body and
  # Sec-Fetch-Site: same-origin on the wire; whichever credential the
  # lane's strategy consults, this request must pass. Without this,
  # "fixing" CSRF could silently break real approvals, and the suite
  # (forgery off globally) would never notice.
  test "consent Approve succeeds as a browser submits it — form token plus Sec-Fetch-Site" do
    post "/oauth/register", params: { client_name: "Claude", redirect_uris: [ HONEST_REDIRECT ] }, as: :json
    client_id = JSON.parse(response.body)["client_id"]
    sign_in @victim

    authorize_params = {
      response_type: "code",
      client_id: client_id,
      redirect_uri: HONEST_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: "https://dummy.test/mcp"
    }

    get "/oauth/authorize", params: authorize_params
    assert_response :success
    token = css_select("input[name=authenticity_token]").first&.attr("value")
    assert token.present?,
      "consent form did not render an authenticity_token — Approve would 422 on token-verified hosts"

    redirect_events = []
    subscriber = ->(event) { redirect_events << event }
    ActiveSupport::Notifications.subscribed(subscriber, "redirect_to.action_controller") do
      post "/oauth/authorize", params: authorize_params.merge(authenticity_token: token),
        headers: BROWSER_SAME_ORIGIN
    end

    assert_response :redirect, "tokened consent Approve was rejected under forgery protection"
    assert_match(/[?&]code=/, response.location, "Approve did not deliver an authorization code")
    assert_empty redirect_events, "authorization codes must not enter Rails redirect instrumentation"
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-cache", response.headers["Pragma"]
  end

  test "consent accepts the standard CSRF header without copying OAuth credentials into Rails params" do
    client_id, authorize_params, token = consent_fixture

    # A same-origin fetch() carries both the CSRF header and Sec-Fetch-Site.
    post "/oauth/authorize", params: authorize_params,
      headers: BROWSER_SAME_ORIGIN.merge("X-CSRF-Token" => token)

    assert_response :redirect
    assert_match(/[?&]code=/, response.location)
    assert_equal client_id, URI.decode_www_form(URI.parse(response.location).query).to_h.fetch("state")
  end

  # A browser-shaped request (token + header) passes under every strategy
  # and proves nothing about which protection is live, so each lane must
  # show the credential its strategy does NOT consult is refused alone.
  # On 8.2 the refused half is also the adopter-facing surprise: a
  # non-browser agent driving the consent form sends the token but not
  # the header, and Rails 422s it (documented in the README).
  test "consent verification trusts exactly the strategy's own credential" do
    _client_id, authorize_params, token = consent_fixture

    if HEADER_VERIFIED
      post "/oauth/authorize", params: authorize_params.merge(authenticity_token: token)
      assert_response :unprocessable_entity,
        "header-only strategy accepted a token with no Sec-Fetch-Site — token fallback is unexpectedly live"

      post "/oauth/authorize", params: authorize_params, headers: BROWSER_SAME_ORIGIN
      assert_response :redirect,
        "header-only strategy refused a same-origin browser POST"
    else
      post "/oauth/authorize", params: authorize_params, headers: BROWSER_SAME_ORIGIN
      assert_response :unprocessable_entity,
        "token strategy accepted Sec-Fetch-Site alone — a header must not stand in for the token"

      post "/oauth/authorize", params: authorize_params.merge(authenticity_token: token)
      assert_response :redirect,
        "token strategy refused the token the rendered form carries"
    end
  end

  # On token-verified lanes these exercise token parsing; on header-only
  # lanes the same requests are refused for lacking the browser header
  # before any token is parsed. Fail-closed either way.
  test "duplicate and structured body CSRF tokens fail closed" do
    _client_id, authorize_params, token = consent_fixture

    duplicate = URI.encode_www_form(
      authorize_params.to_a +
        [ [ "authenticity_token", token ], [ "authenticity_token", token ] ]
    )
    post "/oauth/authorize", params: duplicate,
      headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    assert_response :unprocessable_entity

    structured = URI.encode_www_form(authorize_params.to_a + [ [ "authenticity_token[value]", token ] ])
    post "/oauth/authorize", params: structured,
      headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    assert_response :unprocessable_entity
    assert_equal 0, Hitch::AccessToken.count
  end

  test "oversized consent fails before CSRF and creates no authorization" do
    _client_id, authorize_params, token = consent_fixture
    oversized = URI.encode_www_form(
      authorize_params.to_a + [ [ "authenticity_token", token ], [ "padding", "a" * 20_000 ] ]
    )

    post "/oauth/authorize", params: oversized,
      headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }

    assert_response :content_too_large
    assert_equal 0, Hitch::AccessToken.count
  end

  private

  def consent_fixture
    post "/oauth/register", params: {
      client_name: "Claude",
      redirect_uris: [ HONEST_REDIRECT ]
    }, as: :json
    client_id = JSON.parse(response.body).fetch("client_id")
    sign_in @victim
    authorize_params = {
      response_type: "code",
      client_id: client_id,
      redirect_uri: HONEST_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: "https://dummy.test/mcp",
      state: client_id
    }
    get "/oauth/authorize", params: authorize_params
    token = css_select("input[name=authenticity_token]").first&.attr("value")
    assert token.present?
    [ client_id, authorize_params, token ]
  end
end
