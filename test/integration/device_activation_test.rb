# frozen_string_literal: true

require "test_helper"
require "json"
require "securerandom"

# /activate through a real browser's eyes: the sign-in gate, the §5.4 copy,
# the verification quota, and the decision POSTs. The model tests pin what a
# decision does; these pin who can make one and what the screen tells them.
class DeviceActivationTest < ActionDispatch::IntegrationTest
  RESOURCE = "https://dummy.test/mcp"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::DeviceGrant.delete_all
    Hitch::Client.delete_all
    Hitch.configure do |config|
      config.device_authorization_enabled = true
      config.device_authorization_rate_store = ActiveSupport::Cache::MemoryStore.new
    end
    @user = User.create!(email: "activate+#{SecureRandom.hex(4)}@test")
  end

  def sign_in(user = @user)
    post "/sign_in", params: { user_id: user.id }
    assert_response :success
  end

  def register_client(redirect_uri: "https://claude.ai/api/mcp/auth_callback")
    post "/oauth/register",
      params: { client_name: "Declared Name", redirect_uris: [ redirect_uri ] }.to_json,
      headers: { "Content-Type" => "application/json" }
    assert_response :created
    JSON.parse(response.body).fetch("client_id")
  end

  def register_confidential_dcr
    post "/oauth/register",
      params: {
        client_name: "Attacker-chosen Brand",
        redirect_uris: [ "https://attacker.example/callback" ],
        token_endpoint_auth_method: "client_secret_basic"
      }.to_json,
      headers: { "Content-Type" => "application/json" }
    assert_response :created
    JSON.parse(response.body).fetch("client_id")
  end

  def operator_client(client_name: "Nightly Reporter", redirect_uris: [ "https://agent.example/callback" ])
    Hitch::Client.register_confidential!(
      client_id: "operator-#{SecureRandom.hex(4)}",
      client_name: client_name,
      redirect_uris: redirect_uris,
      operator_registered: true
    ).client
  end

  def mint(client_id: operator_client.client_id)
    Hitch::DeviceGrant.mint!(client_id: client_id, scopes: "mcp", resource_uri: RESOURCE)
  end

  test "the activate page answers 404 while the feature is off" do
    Hitch.configuration.device_authorization_enabled = false
    sign_in

    get "/activate"
    assert_response :not_found

    post "/activate", params: { user_code: "AAAA-AAAA" }
    assert_response :not_found
  end

  test "a signed-out visitor's stored return location drops the live code" do
    get "/activate?user_code=WDJB-MJHT"

    assert_response :unauthorized
    assert_equal "https://www.example.com/activate", session[:return_to_after_authenticating]
    refute_includes session.to_hash.to_s, "WDJB"
  end

  test "the activate page tells the user to enter only a code they asked for" do
    sign_in

    get "/activate"

    assert_response :success
    assert_match(/Only enter a code you asked a device for/, response.body)
    assert_match(/give <em>their<\/em> device access/, response.body)
  end

  test "a prefilled code fills the field and still requires the user to submit" do
    grant = mint
    sign_in

    get "/activate", params: { user_code: grant.raw_user_code.downcase }

    assert_response :success
    display = Hitch::DeviceGrant.display_user_code(grant.raw_user_code)
    assert_includes response.body, %(value="#{display}")
    # Nothing was decided by the GET: the grant is still pending.
    assert Hitch::DeviceGrant.find_pending_by_user_code(grant.raw_user_code)
  end

  test "an operator client is branded by the operator's chosen name, with its provenance stated" do
    grant = mint
    sign_in

    post "/activate", params: { user_code: grant.raw_user_code }

    assert_response :success
    assert_match(/<strong>Nightly Reporter<\/strong>/, response.body)
    assert_match(/registered by this server&#39;s operator/, response.body)
    assert_match(/value="approve"/, response.body)
    assert_includes response.body, Hitch::DeviceGrant.display_user_code(grant.raw_user_code)
    assert_match(/check that your device shows/, response.body)
  end

  test "a self-registered public client's grant reads unverified, even minted around the endpoint" do
    # The mint endpoint refuses these; this pins the second, independent
    # layer — a grant created through the model API still cannot be
    # approved, and claude.ai redirect URIs buy no branding (§5.4).
    grant = mint(client_id: register_client)
    sign_in

    post "/activate", params: { user_code: grant.raw_user_code }
    assert_response :success
    refute_match(/<strong>Claude<\/strong>/, response.body)
    refute_match(/Declared Name/, response.body)
    assert_match(/could not be verified/, response.body)
    refute_match(/value="approve"/, response.body)

    post "/activate", params: { user_code: grant.raw_user_code, decision: "approve" }
    assert_response :success
    assert Hitch::DeviceGrant.find_pending_by_user_code(grant.raw_user_code)
  end

  test "a metadata client is branded by its own document host, the one earned signal" do
    Hitch.configuration.client_id_metadata_enabled = true
    grant = mint(client_id: "https://claude.ai/oauth-client")
    document = Hitch::ClientIdMetadata::Document.new(
      client_id: "https://claude.ai/oauth-client",
      client_name: "Sneaky Declared Name",
      redirect_uris: [ "https://claude.ai/cb" ]
    )
    sign_in

    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(*, **) { document }) do
      post "/activate", params: { user_code: grant.raw_user_code }
    end

    assert_response :success
    assert_match(/<strong>Claude<\/strong>/, response.body)
    refute_match(/Sneaky Declared Name/, response.body)
    refute_match(/registered itself/, response.body)
  end

  test "a confidential client cannot approve a grant minted with public authentication posture" do
    client = operator_client
    grant = Hitch::DeviceGrant.mint!(
      client_id: client.client_id,
      scopes: "mcp",
      resource_uri: RESOURCE,
      token_endpoint_auth_method: "none"
    )
    sign_in

    post "/activate", params: { user_code: grant.raw_user_code }

    assert_response :success
    assert_match(/could not be verified/, response.body)
    refute_match(/value="approve"/, response.body)

    post "/activate", params: { user_code: grant.raw_user_code, decision: "approve" }

    assert_response :success
    assert Hitch::DeviceGrant.find_pending_by_user_code(grant.raw_user_code)
  end

  test "a metadata client cannot approve a grant minted with confidential authentication posture" do
    Hitch.configuration.client_id_metadata_enabled = true
    client_id = "https://agent.example/oauth-client"
    grant = Hitch::DeviceGrant.mint!(
      client_id: client_id,
      scopes: "mcp",
      resource_uri: RESOURCE,
      token_endpoint_auth_method: "client_secret_basic"
    )
    document = Hitch::ClientIdMetadata::Document.new(
      client_id: client_id,
      client_name: "Agent",
      redirect_uris: [ "https://agent.example/cb" ]
    )
    sign_in

    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(*, **) { document }) do
      post "/activate", params: { user_code: grant.raw_user_code }
      assert_response :success
      assert_match(/could not be verified/, response.body)
      refute_match(/value="approve"/, response.body)

      post "/activate", params: { user_code: grant.raw_user_code, decision: "approve" }
    end

    assert_response :success
    assert Hitch::DeviceGrant.find_pending_by_user_code(grant.raw_user_code)
  end

  test "a self-registered client cannot approve a grant minted with confidential authentication posture" do
    grant = Hitch::DeviceGrant.mint!(
      client_id: register_client,
      scopes: "mcp",
      resource_uri: RESOURCE,
      token_endpoint_auth_method: "client_secret_basic"
    )
    sign_in

    post "/activate", params: { user_code: grant.raw_user_code }

    assert_response :success
    assert_match(/could not be verified/, response.body)
    refute_match(/value="approve"/, response.body)

    post "/activate", params: { user_code: grant.raw_user_code, decision: "approve" }

    assert_response :success
    assert Hitch::DeviceGrant.find_pending_by_user_code(grant.raw_user_code)
  end

  test "a confidential DCR client is not displayed or approvable as operator-registered" do
    grant = Hitch::DeviceGrant.mint!(
      client_id: register_confidential_dcr,
      scopes: "mcp",
      resource_uri: RESOURCE,
      token_endpoint_auth_method: "client_secret_basic"
    )
    sign_in

    post "/activate", params: { user_code: grant.raw_user_code }

    assert_response :success
    assert_match(/could not be verified/, response.body)
    refute_match(/Attacker-chosen Brand/, response.body)
    refute_match(/registered by this server&#39;s operator/, response.body)
    refute_match(/value="approve"/, response.body)

    post "/activate", params: { user_code: grant.raw_user_code, decision: "approve" }

    assert_response :success
    assert Hitch::DeviceGrant.find_pending_by_user_code(grant.raw_user_code)
  end

  test "an unknown stored authentication posture fails closed" do
    grant = Struct.new(:token_endpoint_auth_method).new("unknown")
    activation = Hitch::DeviceActivation.new(grant, principal: @user)

    assert_equal true, activation.unverified?
  end

  test "a wrong code gets one vague answer, not a liveness oracle" do
    sign_in

    post "/activate", params: { user_code: "AAAA-AAAA" }

    assert_response :unprocessable_entity
    assert_match(/waiting for approval/, response.body)
  end

  test "approve binds the signed-in user and shows the done page" do
    grant = mint
    sign_in

    post "/activate", params: { user_code: grant.raw_user_code, decision: "approve" }

    assert_response :success
    assert_match(/Device connected/, response.body)
    row = grant.reload
    assert row.approved_at.present?
    assert_equal @user, row.principal
    assert_equal "Nightly Reporter", row.client_name
  end

  test "deny records the refusal and says so" do
    grant = mint
    sign_in

    post "/activate", params: { user_code: grant.raw_user_code, decision: "deny" }

    assert_response :success
    assert_match(/Request denied/, response.body)
    row = grant.reload
    assert row.denied_at.present?
    assert_nil row.approved_at
  end

  test "a decision that is neither approve nor deny decides nothing" do
    grant = mint
    sign_in

    post "/activate", params: { user_code: grant.raw_user_code, decision: "yes" }

    assert_response :unprocessable_entity
    assert_match(/Enter the code again/, response.body)
    row = grant.reload
    assert_nil row.approved_at
    assert_nil row.denied_at
  end

  test "wrong-code attempts beyond the per-principal limit are refused" do
    Hitch.configuration.device_code_verification_limit = { to: 2, within: 60 }
    grant = mint
    sign_in

    2.times { post "/activate", params: { user_code: "AAAA-AAAA" } }
    post "/activate", params: { user_code: grant.raw_user_code, decision: "approve" }

    assert_response :too_many_requests
    assert_equal "60", response.headers["Retry-After"]
    # The limiter refused before the code was even looked at.
    assert_nil grant.reload.approved_at
  end

  test "the verification quota is per principal, so one guesser cannot exhaust another person" do
    Hitch.configuration.device_code_verification_limit = { to: 2, within: 60 }
    other = User.create!(email: "activate-other+#{SecureRandom.hex(4)}@test")
    grant = mint

    sign_in(other)
    3.times { post "/activate", params: { user_code: "AAAA-AAAA" } }
    assert_response :too_many_requests

    sign_in
    post "/activate", params: { user_code: grant.raw_user_code }
    assert_response :success
  end

  test "an operator client with a URL-shaped id renders its operator name and fetches nothing" do
    # hitch:clients:create_confidential bounds-checks but neither parses
    # URIs nor restricts client_id shape; the person's screen must survive
    # both, the registered row must win over CIMD shape, and — even with
    # the metadata scheme on — no remote document may be fetched to
    # overwrite the operator's word.
    Hitch.configuration.client_id_metadata_enabled = true
    client = Hitch::Client.register_confidential!(
      client_id: "https://internal.example/app",
      client_name: "Internal App",
      redirect_uris: [ "https://exa mple.com/cb" ],
      operator_registered: true
    ).client
    grant = mint(client_id: client.client_id)
    fetch_forbidden = ->(*, **) { raise "an operator client must never trigger a metadata fetch" }
    sign_in

    stub_class_method(Hitch::ClientIdMetadata, :resolve, fetch_forbidden) do
      post "/activate", params: { user_code: grant.raw_user_code }
      assert_response :success
      assert_match(/<strong>Internal App<\/strong>/, response.body)
      assert_match(/value="approve"/, response.body)

      post "/activate", params: { user_code: grant.raw_user_code, decision: "approve" }
    end

    assert_response :success
    assert_equal "Internal App", grant.reload.client_name
  end

  test "a registered client deleted while its grant was pending cannot be approved" do
    grant = mint
    Hitch::Client.find_by(client_id: grant.client_id).destroy!
    sign_in

    post "/activate", params: { user_code: grant.raw_user_code }
    assert_response :success
    assert_match(/could not be verified/, response.body)
    refute_match(/value="approve"/, response.body)

    # Driving the approve POST directly answers the same honest screen —
    # the code is live, so "used or expired" would be a lie — and decides
    # nothing.
    post "/activate", params: { user_code: grant.raw_user_code, decision: "approve" }

    assert_response :success
    assert_match(/could not be verified/, response.body)
    assert Hitch::DeviceGrant.find_pending_by_user_code(grant.raw_user_code)
  end

  test "disabling metadata mid-grant leaves the client unverifiable, not anonymously approvable" do
    Hitch.configuration.client_id_metadata_enabled = true
    grant = mint(client_id: "https://agent.example/oauth-client")
    Hitch.configuration.client_id_metadata_enabled = false
    resolve_forbidden = ->(*, **) { raise "a disabled scheme must not fetch" }
    sign_in

    stub_class_method(Hitch::ClientIdMetadata, :resolve, resolve_forbidden) do
      post "/activate", params: { user_code: grant.raw_user_code }
      assert_response :success
      assert_match(/could not be verified/, response.body)
      refute_match(/value="approve"/, response.body)

      post "/activate", params: { user_code: grant.raw_user_code, decision: "approve" }
    end

    assert_response :success
    assert_match(/could not be verified/, response.body)
    assert Hitch::DeviceGrant.find_pending_by_user_code(grant.raw_user_code)
  end

  test "an empty code answers with the form in plain words and spends no guessing budget" do
    Hitch.configuration.device_code_verification_limit = { to: 1, within: 60 }
    grant = mint
    sign_in

    # Present-but-blank and absent entirely — a broken form drops the
    # field; neither is a guess.
    3.times do
      post "/activate", params: { user_code: "" }
      assert_response :unprocessable_entity
      assert_match(/Enter the code your device is showing/, response.body)
    end
    3.times do
      post "/activate", params: { decision: "approve" }
      assert_response :unprocessable_entity
      assert_match(/Enter the code your device is showing/, response.body)
    end

    # The one counted attempt is still available: empty submissions were
    # not charged against the §5.1 budget.
    post "/activate", params: { user_code: grant.raw_user_code }
    assert_response :success
    assert_match(/is asking for access/, response.body)
  end

  test "an oversized submission answers with the form in plain words, not JSON" do
    sign_in

    post "/activate", params: { user_code: "A" * 20_000 }

    assert_response :content_too_large
    assert_match(/too large/, response.body)
    assert_match(/Only enter a code you asked a device for/, response.body)
  end

  test "an oversized body to the disabled activate endpoint answers 404, not a body-cap error" do
    Hitch.configuration.device_authorization_enabled = false

    post "/activate", params: { user_code: "A" * 20_000 }

    assert_response :not_found
    assert_empty response.body
  end

  test "an unverifiable metadata client shows no Approve and the grant stays pending" do
    Hitch.configuration.client_id_metadata_enabled = true
    grant = mint(client_id: "https://agent.example/oauth-client")
    resolve_nothing = ->(*, **) { nil }
    sign_in

    stub_class_method(Hitch::ClientIdMetadata, :resolve, resolve_nothing) do
      post "/activate", params: { user_code: grant.raw_user_code }
      assert_response :success
      assert_match(/could not be verified/, response.body)
      refute_match(/value="approve"/, response.body)

      # Driving the approve POST directly must not work either — it answers
      # the same honest could-not-verify screen, since the failure may be a
      # transient fetch and the code itself is live.
      post "/activate", params: { user_code: grant.raw_user_code, decision: "approve" }
    end

    assert_response :success
    assert_match(/could not be verified/, response.body)
    assert Hitch::DeviceGrant.find_pending_by_user_code(grant.raw_user_code)
  end

  test "a non-HTML request still gets the HTML page, never a template 500" do
    grant = mint
    sign_in

    get "/activate.json"
    assert_response :success
    assert_match(/Only enter a code you asked a device for/, response.body)

    post "/activate", params: { user_code: grant.raw_user_code },
      headers: { "Accept" => "application/json" }
    assert_response :success
    assert_match(/check that your device shows/, response.body)
  end

  test "the approve form cannot be submitted without a CSRF credential" do
    grant = mint
    sign_in
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    begin
      post "/activate", params: { user_code: grant.raw_user_code, decision: "approve" }
      assert_response :unprocessable_entity

      post "/activate",
        params: { user_code: grant.raw_user_code, decision: "approve" },
        headers: { "Sec-Fetch-Site" => "cross-site" }
      assert_response :unprocessable_entity
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    assert_nil grant.reload.approved_at
  end

  test "a browser's own submit approves with forgery protection on" do
    grant = mint
    sign_in
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    begin
      get "/activate"
      assert_response :success
      token = response.body[/name="authenticity_token" value="([^"]+)"/, 1]

      post "/activate",
        params: {
          user_code: grant.raw_user_code, decision: "approve", authenticity_token: token
        },
        headers: { "Sec-Fetch-Site" => "same-origin" }
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    assert_response :success
    assert grant.reload.approved_at.present?
  end
end
