# frozen_string_literal: true

require "test_helper"
require "digest"
require "base64"
require "securerandom"

class OAuthFlowTest < ActionDispatch::IntegrationTest
  RESOURCE_A = "https://dummy.test/mcp"
  RESOURCE_B = "https://other.test/mcp"
  CLIENT_REDIRECT = "https://claude.ai/callback"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |c|
      c.resource_uri = RESOURCE_A
      c.allowed_hosts = [ "www.example.com", "mcp.example.com" ]
      c.allowed_origins = [ "https://claude.ai" ]
      c.brand_name = "Dummy"
    end
    @user = User.create!(email: "tester@test")
    @verifier = SecureRandom.urlsafe_base64(64)
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
  end

  def sign_in(user)
    post "/sign_in", params: { user_id: user.id }
    assert_response :success
  end

  def register_client(name: "Claude Code", redirect_uris: [ CLIENT_REDIRECT ])
    post "/oauth/register", params: { client_name: name, redirect_uris: redirect_uris }, as: :json
    assert_response :created
    JSON.parse(response.body)
  end

  test "discovery metadata exposes authorization + protected resource endpoints" do
    get "/.well-known/oauth-authorization-server"
    body = JSON.parse(response.body)
    # Pin the issuer VALUE, not just its presence. RFC 8414 §2 requires it
    # be the URL the metadata is served from, and clients validate that;
    # asserting only presence would let any wrong-but-self-consistent
    # issuer through, including one carrying a stray path suffix.
    assert_equal "https://dummy.test", body["issuer"]
    assert_equal "https://dummy.test/oauth/authorize", body["authorization_endpoint"]
    assert_equal "https://dummy.test/oauth/token", body["token_endpoint"]
    assert_equal "https://dummy.test/oauth/register", body["registration_endpoint"]
    assert_equal [ "S256" ], body["code_challenge_methods_supported"]
    assert_equal [ "mcp" ], body["scopes_supported"]
    # Advertise exactly the two implemented methods; client_secret_post
    # remains unsupported because secrets never belong in the form body.
    assert_equal %w[none client_secret_basic], body["token_endpoint_auth_methods_supported"]
    assert_equal true, body["authorization_response_iss_parameter_supported"]

    get "/.well-known/oauth-protected-resource"
    body = JSON.parse(response.body)
    assert_equal RESOURCE_A, body["resource"]
    # Also derived from Hitch::IssuerUrl — pinned so the helper can't
    # drift here unnoticed either.
    assert_equal [ "https://dummy.test" ], body["authorization_servers"]
    assert_equal [ "header" ], body["bearer_methods_supported"]
    # PRM SHOULD include scopes_supported (2026-07-28 spec) so RSes
    # can echo per-tool required scopes in 403 challenges.
    assert_equal [ "mcp" ], body["scopes_supported"]
  end

  # RFC 9207 §2: the `iss` value "MUST be a URL that uses the 'https'
  # scheme". Advertising support while emitting an http issuer would be
  # promising conformance the server cannot deliver — and per the spec's
  # validation table, an advertised-but-unusable value is exactly what
  # makes a conformant client hard-fail.
  test "the RFC 9207 capability is advertised only when the issuer is https" do
    get "/.well-known/oauth-authorization-server"
    assert_equal "https://dummy.test", JSON.parse(response.body)["issuer"]
    assert_equal true, JSON.parse(response.body)["authorization_response_iss_parameter_supported"]

    Hitch.configuration.resource_uri = "http://127.0.0.1/mcp"
    host! "127.0.0.1"
    https!(false)
    get "/.well-known/oauth-authorization-server"
    body = JSON.parse(response.body)
    assert_equal "http://127.0.0.1", body["issuer"]
    assert_equal false, body["authorization_response_iss_parameter_supported"]
  end

  # An http `iss` is NOT conformant — RFC 9207 §2 requires the value use
  # the https scheme, and withholding the advertisement does not change
  # that. It is emitted anyway as deliberate development compatibility,
  # so a local flow exercises the same path as production instead of the
  # parameter appearing for the first time on deploy. An http deployment
  # is already outside the spec regardless (MCP 2026-07-28 requires every
  # authorization server endpoint be served over HTTPS). A client that
  # already accepted the http issuer from the same discovery document can
  # compare the two and pass; a stricter one may reject the http issuer
  # during discovery and never get here at all.
  test "iss is emitted for configured loopback http development, unadvertised" do
    local_resource = "http://127.0.0.1/mcp"
    Hitch.configuration.resource_uri = local_resource
    host! "127.0.0.1"
    https!(false)
    client = register_client
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"], redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge, code_challenge_method: "S256", resource: local_resource
    }
    assert_response :redirect
    returned = URI.decode_www_form(URI.parse(response.location).query).to_h
    assert_equal "http://127.0.0.1", returned["iss"]
  end

  # Metadata is fixed to the configured resource origin. Responses remain
  # private and vary on Host as defense in depth for virtual-host caches.
  test "discovery metadata is not shared-cacheable and varies on Host" do
    %w[/.well-known/oauth-authorization-server /.well-known/oauth-protected-resource].each do |path|
      get path
      cache_control = response.headers["Cache-Control"].to_s
      assert_not_includes cache_control, "public",
        "#{path} must not become shared-cacheable"
      assert_includes cache_control, "private", "#{path} should be privately cacheable"
      assert_includes response.headers["Vary"].to_s, "Host",
        "#{path} must Vary on Host so caches don't serve a forged-Host response cross-host"
    end
  end

  test "CORS preflight on .well-known/*" do
    headers = {
      "Origin" => "https://claude.ai",
      "Access-Control-Request-Method" => "GET"
    }
    process :options, "/.well-known/oauth-authorization-server", headers: headers
    assert_response :no_content
    assert_equal "https://claude.ai", response.headers["Access-Control-Allow-Origin"]

    process :options, "/.well-known/oauth-protected-resource", headers: headers
    assert_response :no_content
    assert_equal "https://claude.ai", response.headers["Access-Control-Allow-Origin"]
  end

  # MCP 2026-07-28 makes these required request headers on Streamable
  # HTTP. A browser-based client that sends them fails preflight unless
  # they're allowed, so the allow-list has to name them explicitly —
  # there is no wildcard fallback once Authorization is in play.
  test "CORS preflight allows the MCP 2026-07-28 request headers" do
    requested = %w[Content-Type Authorization MCP-Protocol-Version Mcp-Method Mcp-Name]
    process :options, "/oauth/token", headers: {
      "Origin" => "https://claude.ai",
      "Access-Control-Request-Method" => "POST",
      "Access-Control-Request-Headers" => requested.join(", ")
    }
    allowed = response.headers["Access-Control-Allow-Headers"].to_s

    requested.each do |header|
      assert_includes allowed, header,
        "#{header} must be in Access-Control-Allow-Headers or browser MCP clients fail preflight"
    end
  end

  test "DCR rejects javascript: redirect_uri" do
    post "/oauth/register", params: { client_name: "Bad", redirect_uris: [ "javascript:alert(1)" ] }, as: :json
    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_equal "invalid_redirect_uri", body["error"]
  end

  test "DCR rejects non-loopback http redirect_uri" do
    post "/oauth/register", params: { client_name: "Bad", redirect_uris: [ "http://attacker.test/cb" ] }, as: :json
    assert_response :bad_request
    assert_equal "invalid_redirect_uri", JSON.parse(response.body)["error"]
  end

  test "DCR allows http loopback redirect_uri" do
    post "/oauth/register", params: { client_name: "Local", redirect_uris: [ "http://localhost:8080/cb" ] }, as: :json
    assert_response :created
  end

  test "DCR rejects when one of multiple redirect_uris is bad" do
    post "/oauth/register", params: { client_name: "Mixed", redirect_uris: [ "https://app.test/cb", "javascript:1" ] }, as: :json
    assert_response :bad_request
  end

  test "authorize matches loopback redirect_uri port-agnostically (RFC 8252)" do
    # Client registers http://localhost:9000/cb but the inbound request
    # uses an ephemeral port 54321 — must still be accepted.
    client = register_client(redirect_uris: [ "http://localhost:9000/cb" ])
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: "http://localhost:54321/cb",
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE_A
    }
    assert_response :redirect
    assert response.location.start_with?("http://localhost:54321/cb")
  end

  test "authorize still rejects loopback redirect_uri with mismatched path" do
    client = register_client(redirect_uris: [ "http://localhost:9000/cb" ])
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: "http://localhost:9000/different/path",
      code_challenge: @challenge,
      code_challenge_method: "S256"
    }
    assert_response :bad_request
  end

  # RFC 9700 §4.1.3 and MCP 2026-07-28 both require exact matching, with
  # RFC 8252 §7.3 granting one carve-out: the PORT of a loopback
  # redirect. Anything else that differs from the registration is a
  # different URI, and a caller who can craft an authorize URL must not
  # be able to add parameters a client's callback will read.
  test "authorize rejects a redirect_uri whose query differs from the registration" do
    client = register_client(redirect_uris: [ "https://app.test/cb?tenant=acme" ])
    sign_in @user

    [
      "https://app.test/cb",                    # query dropped
      "https://app.test/cb?tenant=evil",        # value changed
      "https://app.test/cb?tenant=acme&next=x", # parameter added
      "https://app.test/cb?TENANT=acme"         # key case changed
    ].each do |inbound|
      post "/oauth/authorize", params: {
      response_type: "code",
        client_id: client["client_id"], redirect_uri: inbound,
        code_challenge: @challenge, code_challenge_method: "S256"
      }
      assert_response :bad_request, "#{inbound} is not an exact match for the registration"
    end
  end

  test "authorize accepts the exact registered redirect_uri including its query" do
    client = register_client(redirect_uris: [ "https://app.test/cb?tenant=acme" ])
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"], redirect_uri: "https://app.test/cb?tenant=acme",
      code_challenge: @challenge, code_challenge_method: "S256", resource: RESOURCE_A
    }
    assert_response :redirect
    assert_includes response.location, "tenant=acme"
  end

  # A userinfo component would let https://evil%40x:pw@app.test/cb match
  # a registration of https://app.test/cb — same host to URI.parse, very
  # different string to a user reading the address bar.
  test "authorize rejects a redirect_uri carrying userinfo" do
    client = register_client(redirect_uris: [ "https://app.test/cb" ])
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"], redirect_uri: "https://evil%40x:pw@app.test/cb",
      code_challenge: @challenge, code_challenge_method: "S256"
    }
    assert_response :bad_request
  end

  # The loopback carve-out is the port and nothing else.
  test "loopback matching stays port-agnostic but not query-agnostic" do
    client = register_client(redirect_uris: [ "http://localhost:9000/cb" ])
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"], redirect_uri: "http://localhost:54321/cb?extra=1",
      code_challenge: @challenge, code_challenge_method: "S256"
    }
    assert_response :bad_request, "an ephemeral port is permitted; an added query parameter is not"
  end

  test "authorize still rejects non-loopback host even if port matches" do
    client = register_client(redirect_uris: [ "https://app.test/cb" ])
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: "https://attacker.test/cb",
      code_challenge: @challenge,
      code_challenge_method: "S256"
    }
    assert_response :bad_request
  end

  test "DCR returns client_id + persists Client row" do
    body = register_client
    assert body["client_id"].present?
    assert_equal "Claude Code", body["client_name"]
    assert_equal [ CLIENT_REDIRECT ], body["redirect_uris"]
    assert Hitch::Client.exists?(client_id: body["client_id"])
  end

  # RFC 7591 §3.2.1 makes the registration response the authoritative
  # record of what was registered, so the server echoes what it STORED,
  # not what was sent — a client sending an unrecognized value learns it
  # was dropped instead of assuming it took effect.
  test "DCR records and echoes a declared application_type" do
    post "/oauth/register", params: {
      client_name: "Claude Code", redirect_uris: [ "http://localhost:8080/cb" ], application_type: "native"
    }, as: :json
    assert_response :created
    assert_equal "native", JSON.parse(response.body)["application_type"]
    assert_equal "native", Hitch::Client.last.application_type
  end

  test "DCR drops an unrecognized application_type without failing the registration" do
    post "/oauth/register", params: {
      client_name: "Odd", redirect_uris: [ CLIENT_REDIRECT ], application_type: "desktop"
    }, as: :json
    assert_response :created
    assert_nil JSON.parse(response.body)["application_type"]
    assert_nil Hitch::Client.last.application_type
  end

  # The field is recorded, never enforced. A client that omits it must
  # keep working exactly as before — including the loopback redirect that
  # a future `application_type == "native"` gate would otherwise break.
  # Claude Code omits it today, so this is the regression that matters.
  test "a client that declares no application_type still gets loopback redirects" do
    client = register_client(redirect_uris: [ "http://localhost:9000/cb" ])
    assert_nil Hitch::Client.find_by(client_id: client["client_id"]).application_type
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: "http://localhost:54321/cb",
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE_A
    }
    assert_response :redirect
    assert response.location.start_with?("http://localhost:54321/cb")
  end

  # Equally: declaring "web" must NOT currently restrict anything. If
  # enforcement is ever added it will be a deliberate, separately-tracked
  # change — not something that arrives silently with this column.
  test "declaring web does not restrict a loopback redirect (no enforcement yet)" do
    post "/oauth/register", params: {
      client_name: "Weblike", redirect_uris: [ "http://localhost:9000/cb" ], application_type: "web"
    }, as: :json
    assert_response :created
    client = JSON.parse(response.body)
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: "http://localhost:54321/cb",
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE_A
    }
    assert_response :redirect
    # Assert the destination, not just that SOME redirect happened. If
    # enforcement is ever added the RFC 6749 §4.1.2.1-conformant way — an
    # error redirect back to the client — a bare `assert_response
    # :redirect` would still pass while the flow was actually refused.
    assert response.location.start_with?("http://localhost:54321/cb")
    assert_includes response.location, "code="
  end

  # --- Client ID Metadata Documents (MCP 2026-07-28) -------------------

  CIMD_URL = "https://client.example/metadata.json"

  def cimd_document(redirect_uris: [ CLIENT_REDIRECT ], client_name: "Doc Client")
    Hitch::ClientIdMetadata::Document.new(
      client_id: CIMD_URL, client_name: client_name, redirect_uris: redirect_uris
    )
  end

  # The flag is what makes a conformant client stop falling back to DCR
  # and send a document URL as its client_id. Advertising it while the
  # server would reject every such client_id converts a working DCR flow
  # into a broken one, so it tracks the config exactly.
  test "the CIMD capability tracks the config in both directions" do
    # Off by default, so nothing is advertised until a host opts in.
    get "/.well-known/oauth-authorization-server"
    assert_nil JSON.parse(response.body)["client_id_metadata_document_supported"]

    Hitch.configure { |c| c.client_id_metadata_enabled = true }
    get "/.well-known/oauth-authorization-server"
    assert_equal true, JSON.parse(response.body)["client_id_metadata_document_supported"]

    # Withdrawing it matters as much as advertising it: a client reads
    # this flag to decide whether to send a document URL at all, so a
    # server that stops supporting CIMD without withdrawing the
    # advertisement breaks every client that believed it.
    Hitch.configure { |c| c.client_id_metadata_enabled = false }
    get "/.well-known/oauth-authorization-server"
    assert_nil JSON.parse(response.body)["client_id_metadata_document_supported"]
  end

  test "an https client_id is an opaque unknown client while CIMD is disabled" do
    Hitch.configure { |c| c.client_id_metadata_enabled = false }
    sign_in @user
    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { flunk "must not resolve while disabled" }) do
      post "/oauth/authorize", params: {
        response_type: "code",
        client_id: CIMD_URL, redirect_uri: CLIENT_REDIRECT,
        code_challenge: @challenge, code_challenge_method: "S256", resource: RESOURCE_A
      }
      assert_response :bad_request
      assert_equal "invalid_client", JSON.parse(response.body)["error"]
    end
  end

  test "a resolved metadata document authorizes like a registered client" do
    Hitch.configure { |c| c.client_id_metadata_enabled = true }
    sign_in @user

    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { cimd_document }) do
      post "/oauth/authorize", params: {
      response_type: "code",
        client_id: CIMD_URL, redirect_uri: CLIENT_REDIRECT,
        code_challenge: @challenge, code_challenge_method: "S256",
        state: "xyz", resource: RESOURCE_A
      }
      assert_response :redirect
      assert response.location.start_with?(CLIENT_REDIRECT)
    end

    # No Hitch::Client row is created — a fetched document is not a
    # registration. Audit continuity lives on the token instead.
    assert_equal 0, Hitch::Client.count
    token = Hitch::AccessToken.last
    assert_equal CIMD_URL, token.client_id
    assert_equal "Doc Client", token.client_name
  end

  test "a redirect_uri absent from the resolved document is refused" do
    Hitch.configure { |c| c.client_id_metadata_enabled = true }
    sign_in @user

    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { cimd_document }) do
      post "/oauth/authorize", params: {
        response_type: "code",
        client_id: CIMD_URL, redirect_uri: "https://attacker.test/cb",
        code_challenge: @challenge, code_challenge_method: "S256", resource: RESOURCE_A
      }
      assert_response :bad_request
    end
  end

  test "an unresolvable metadata document is an invalid_client, not a 500" do
    Hitch.configure { |c| c.client_id_metadata_enabled = true }
    sign_in @user

    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { nil }) do
      post "/oauth/authorize", params: {
        response_type: "code",
        client_id: CIMD_URL, redirect_uri: CLIENT_REDIRECT,
        code_challenge: @challenge, code_challenge_method: "S256", resource: RESOURCE_A
      }
      assert_response :bad_request
      assert_equal "invalid_client", JSON.parse(response.body)["error"]
    end
  end

  # A metadata document never passes through /oauth/register, so the
  # https-or-loopback policy DCR clients face has to be applied here
  # instead — otherwise CIMD is a way to register a redirect_uri that
  # DCR would have rejected outright.
  test "document redirect_uris must still satisfy the gem's URI policy" do
    Hitch.configure { |c| c.client_id_metadata_enabled = true }
    sign_in @user

    # The inbound redirect_uri is deliberately a VALID one, so it clears
    # the request-level guard and execution actually reaches the filter
    # under test. The document declares only URIs the gem's policy
    # rejects, so filtering leaves nothing — and the error_description
    # distinguishes "filtered to empty" from "did not match", which is
    # what makes this test fail if the filter is removed rather than
    # passing for an unrelated reason.
    hostile = cimd_document(redirect_uris: [ "javascript:alert(1)", "http://attacker.test/cb" ])
    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { hostile }) do
      post "/oauth/authorize", params: {
        response_type: "code",
        client_id: CIMD_URL, redirect_uri: CLIENT_REDIRECT,
        code_challenge: @challenge, code_challenge_method: "S256", resource: RESOURCE_A
      }
      assert_response :bad_request
      assert_equal "client has no usable redirect_uris",
        JSON.parse(response.body)["error_description"],
        "the document's URIs must be filtered by the gem's policy, not merely fail to match"
    end
  end

  # The "client_name is attacker-controllable, never trust it for
  # display" invariant is cited in three separate places in the source
  # and had no coverage in either registration scheme. The consent screen
  # must derive its display name from the VERIFIED redirect_uri host.
  test "a client's declared name never reaches the consent screen (DCR)" do
    client = register_client(name: "<script>alert(1)</script>Trusted Bank")
    sign_in @user

    get "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"], redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge, code_challenge_method: "S256", resource: RESOURCE_A
    }
    assert_response :success
    assert_not_includes response.body, "Trusted Bank"
    assert_not_includes response.body, "alert(1)"
    assert_includes response.body, "Claude" # derived from the redirect_uri host
  end

  # MCP 2026-07-28 security considerations: a metadata document "cannot
  # prevent localhost URL impersonation by itself", so the server SHOULD
  # warn when a client's redirect URIs are localhost-only. Anyone can
  # host a document claiming any name and point it at a loopback port;
  # nothing in the document proves which program is listening there.
  test "a localhost-only CIMD client raises a warning on the consent screen" do
    Hitch.configure { |c| c.client_id_metadata_enabled = true }
    sign_in @user

    local = cimd_document(redirect_uris: [ "http://localhost:9000/cb", "http://127.0.0.1:9000/cb" ])
    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { local }) do
      get "/oauth/authorize", params: {
      response_type: "code",
        client_id: CIMD_URL, redirect_uri: "http://localhost:9000/cb",
        code_challenge: @challenge, code_challenge_method: "S256", resource: RESOURCE_A
      }
      assert_response :success
      assert_includes response.body, "runs on your own computer"
    end
  end

  test "a CIMD client with a remote redirect_uri raises no localhost warning" do
    Hitch.configure { |c| c.client_id_metadata_enabled = true }
    sign_in @user

    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { cimd_document }) do
      get "/oauth/authorize", params: {
      response_type: "code",
        client_id: CIMD_URL, redirect_uri: CLIENT_REDIRECT,
        code_challenge: @challenge, code_challenge_method: "S256", resource: RESOURCE_A
      }
      assert_response :success
      assert_not_includes response.body, "runs on your own computer"
    end
  end

  # Every other rate-limit test calls resolve directly with an actor.
  # Removing `actor: rate_limit_actor` from the controller would leave
  # all of them green while the shipped per-principal limit did nothing,
  # so this drives it through the real endpoint as a signed-in user.
  test "the per-principal fetch limit applies through /oauth/authorize" do
    real_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Hitch.configure do |c|
      c.client_id_metadata_enabled = true
      c.client_id_metadata_fetches_per_minute = 2
    end
    sign_in @user
    fetches = 0

    begin
      stub_class_method(Hitch::ClientIdMetadata, :fetch_and_validate, ->(_id, *) { fetches += 1; nil }) do
        5.times do |i|
          post "/oauth/authorize", params: {
            response_type: "code",
            client_id: "https://client.example/doc#{i}.json", redirect_uri: CLIENT_REDIRECT,
            code_challenge: @challenge, code_challenge_method: "S256", resource: RESOURCE_A
          }
          assert_response :bad_request
        end
      end
      assert_equal 2, fetches,
        "distinct document URLs must still be bounded per principal — that is the amplification guard"
    ensure
      Rails.cache = real_cache
    end
  end

  test "a client's declared name never reaches the consent screen (CIMD)" do
    Hitch.configure { |c| c.client_id_metadata_enabled = true }
    sign_in @user

    document = cimd_document(client_name: "<script>alert(1)</script>Trusted Bank")
    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { document }) do
      get "/oauth/authorize", params: {
      response_type: "code",
        client_id: CIMD_URL, redirect_uri: CLIENT_REDIRECT,
        code_challenge: @challenge, code_challenge_method: "S256", resource: RESOURCE_A
      }
      assert_response :success
      assert_not_includes response.body, "Trusted Bank"
      assert_not_includes response.body, "alert(1)"
    end
  end

  test "happy path: register → authorize → token exchange → token usable" do
    client = register_client
    sign_in @user

    # Consent screen renders for authenticated user
    get "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      state: "xyz",
      resource: RESOURCE_A
    }
    assert_response :success
    assert_includes response.body, "Claude"

    # User approves
    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      state: "xyz",
      resource: RESOURCE_A
    }
    assert_response :redirect
    redirect_location = response.location
    assert redirect_location.start_with?(CLIENT_REDIRECT)

    code = URI.decode_www_form(URI.parse(redirect_location).query).to_h["code"]
    assert code.present?
    assert_includes redirect_location, "state=xyz"

    # Token exchange
    post "/oauth/token", params: {
      grant_type: "authorization_code",
      code: code,
      client_id: client["client_id"],
      code_verifier: @verifier,
      resource: RESOURCE_A
    }
    assert_response :success
    body = JSON.parse(response.body)
    assert body["access_token"].present?
    assert_equal "Bearer", body["token_type"]
    assert_equal "mcp", body["scope"]
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-cache", response.headers["Pragma"]

    # The minted token is bound to the configured resource (RFC 8707)
    raw_token = body["access_token"]
    record = Hitch::AccessToken.find_by_token(raw_token)
    assert record.present?
    assert record.valid_for_resource?(RESOURCE_A)
    refute record.valid_for_resource?(RESOURCE_B)
  end

  # RFC 6749 §4.1.3: a redirect_uri presented at the token endpoint MUST be
  # identical to the one the code was issued to. The mismatch is rejected
  # before the code is consumed, so a client can retry correctly.
  test "token exchange rejects a mismatched redirect_uri and keeps the code" do
    client = register_client
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"], redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge, code_challenge_method: "S256", resource: RESOURCE_A
    }
    code = URI.decode_www_form(URI.parse(response.location).query).to_h["code"]

    post "/oauth/token", params: {
      grant_type: "authorization_code", code: code,
      client_id: client["client_id"], code_verifier: @verifier,
      resource: RESOURCE_A, redirect_uri: "https://claude.ai/other"
    }
    assert_response :bad_request
    assert_equal "invalid_grant", JSON.parse(response.body)["error"]

    post "/oauth/token", params: {
      grant_type: "authorization_code", code: code,
      client_id: client["client_id"], code_verifier: @verifier,
      resource: RESOURCE_A, redirect_uri: CLIENT_REDIRECT
    }
    assert_response :success
    assert JSON.parse(response.body)["access_token"].present?
  end

  # RFC 9207 §2.4: the client compares the authorization response's `iss`
  # against the issuer it discovered, with an exact string comparison,
  # and refuses to exchange the code on any mismatch. Asserting mere
  # presence would pass while the flow still dead-ends at a real client,
  # so both values are read in one test and compared directly.
  test "authorization response carries iss byte-identical to the advertised issuer (RFC 9207)" do
    # Both with and without `state`: it is RECOMMENDED, not required, in
    # OAuth 2.1, and PKCE-only clients routinely omit it. `iss` must not
    # ride along on the state branch — the metadata advertises it
    # unconditionally, so an omission is a hard failure at the client.
    #
    # Run through an allowed ingress alias. The alias must never become a
    # second issuer identity; both values use the fixed resource_uri origin.
    [ nil, "xyz" ].each do |state|
      host! "mcp.example.com"

      get "/.well-known/oauth-authorization-server"
      advertised_issuer = JSON.parse(response.body)["issuer"]
      assert_equal "https://dummy.test", advertised_issuer

      client = register_client
      sign_in @user

      post "/oauth/authorize", params: {
      response_type: "code",
        client_id: client["client_id"],
        redirect_uri: CLIENT_REDIRECT,
        code_challenge: @challenge,
        code_challenge_method: "S256",
        resource: RESOURCE_A
      }.merge(state ? { state: state } : {})
      assert_response :redirect

      returned = URI.decode_www_form(URI.parse(response.location).query).to_h
      assert_equal advertised_issuer, returned["iss"],
        "iss must equal the advertised issuer exactly (state=#{state.inspect}) — a conformant client refuses the exchange otherwise"
    end
  end

  # Exact matching (see redirect_uri_matches?) rejects an unregistered
  # query outright, so this covers the case it cannot: a client whose
  # REGISTERED redirect_uri already carries a response parameter. The
  # match succeeds there, and without stripping the response would carry
  # `iss` twice — which copy wins is a property of the client's query
  # parser, and a first-wins parser (URLSearchParams, Go's Query().Get,
  # Python's parse_qs) would read the registered value and send its code
  # exchange to whatever token endpoint that names. Exactly the mix-up
  # RFC 9207 exists to stop, on a defense the discovery document promises.
  test "an injected iss in the redirect_uri query is refused outright" do
    client = register_client(redirect_uris: [ CLIENT_REDIRECT ])
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: "#{CLIENT_REDIRECT}?iss=https%3A%2F%2Fattacker-as.example",
      code_challenge: @challenge,
      code_challenge_method: "S256",
      state: "xyz",
      resource: RESOURCE_A
    }
    # The registration carried no query, so this is not an exact match
    # and never reaches the redirect builder at all (RFC 9700 §4.1.3).
    assert_response :bad_request
    assert_equal "invalid_request", JSON.parse(response.body)["error"]
  end

  # Defense in depth for the case exact matching cannot catch: a client
  # that legitimately REGISTERED a query string containing a response
  # parameter. The match succeeds, so the stripping in build_redirect_uri
  # is the only thing standing between that and a duplicated `iss` — and
  # which copy a client honors is a property of its query parser.
  test "a registered iss in the redirect_uri query is stripped from the response" do
    poisoned = "#{CLIENT_REDIRECT}?iss=https%3A%2F%2Fattacker-as.example"
    client = register_client(redirect_uris: [ poisoned ])
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: poisoned,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      state: "xyz",
      resource: RESOURCE_A
    }
    assert_response :redirect

    pairs = URI.decode_www_form(URI.parse(response.location).query)
    issuers = pairs.select { |k, _| k == "iss" }.map(&:last)
    assert_equal 1, issuers.length,
      "the authorization response must carry exactly one iss — a duplicate is shadowable by a first-wins client parser"
    assert_equal "https://dummy.test", issuers.first
    assert_not_includes response.location, "attacker-as.example"
  end

  # RFC 6749 §4.1.2 makes `error` and `code` mutually exclusive, so client
  # libraries branch on `error` first: an injected one makes the client
  # discard a code the victim genuinely approved. And `error_description`
  # / `error_uri` get rendered as UI copy and a "more information" link
  # inside the real client's trusted error surface, both written by the
  # attacker. Reachable without the query-matching gap at all —
  # registration is unauthenticated, so an attacker registers their own
  # client pointing at someone else's callback.
  test "injected error parameters in the redirect_uri query are stripped" do
    poisoned = "#{CLIENT_REDIRECT}?error=access_denied" \
               "&error_description=Session+expired.+Re-authenticate+at+evil.example" \
               "&error_uri=https%3A%2F%2Fevil.example%2Ffix"
    client = register_client(redirect_uris: [ poisoned ])
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: poisoned,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      state: "xyz",
      resource: RESOURCE_A
    }
    assert_response :redirect

    returned = URI.decode_www_form(URI.parse(response.location).query).to_h
    assert_nil returned["error"], "an injected error would make the client discard a code the user approved"
    assert_nil returned["error_description"]
    assert_nil returned["error_uri"]
    assert_not_includes response.location, "evil.example"
    assert returned["code"].present?
  end

  # RFC 6749 §3.1.2: the redirection endpoint MUST NOT include a fragment.
  # redirect_uri_matches? ignores fragments, so one would ride through
  # unvalidated to a client that reads response params from location.hash.
  test "DCR rejects a redirect_uri carrying a fragment" do
    post "/oauth/register", params: {
      client_name: "Fragment", redirect_uris: [ "#{CLIENT_REDIRECT}#iss=https://attacker.example" ]
    }, as: :json
    assert_response :bad_request
    assert_equal "invalid_redirect_uri", JSON.parse(response.body)["error"]
  end

  test "DCR rejects syntactically present empty fragment and userinfo components" do
    [ "#{CLIENT_REDIRECT}#", "https://@claude.ai/callback" ].each do |redirect_uri|
      post "/oauth/register", params: {
        client_name: "Empty component", redirect_uris: [ redirect_uri ]
      }, as: :json

      assert_response :bad_request
      assert_equal "invalid_redirect_uri", JSON.parse(response.body).fetch("error")
    end
  end

  test "authorize rejects syntactically present empty fragment and userinfo components" do
    client = register_client
    sign_in @user

    [ "#{CLIENT_REDIRECT}#", "https://@claude.ai/callback" ].each do |redirect_uri|
      post "/oauth/authorize", params: {
        response_type: "code",
        client_id: client.fetch("client_id"),
        redirect_uri: redirect_uri,
        code_challenge: @challenge,
        code_challenge_method: "S256",
        resource: RESOURCE_A
      }

      assert_response :bad_request
    end
  end

  # Same primitive applied to code/state. Mandatory S256 PKCE blunts the
  # code case today (an injected code is bound to the attacker's
  # challenge), but the injection itself is what closes here.
  test "registered code and state in the redirect_uri query cannot shadow the real ones" do
    poisoned = "#{CLIENT_REDIRECT}?code=ATTACKER_CODE&state=ATTACKER_STATE"
    client = register_client(redirect_uris: [ poisoned ])
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: poisoned,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      state: "xyz",
      resource: RESOURCE_A
    }
    assert_response :redirect

    pairs = URI.decode_www_form(URI.parse(response.location).query)
    assert_equal 1, pairs.count { |k, _| k == "code" }
    assert_equal 1, pairs.count { |k, _| k == "state" }
    assert_not_includes response.location, "ATTACKER_CODE"
    assert_not_includes response.location, "ATTACKER_STATE"
    assert_equal "xyz", pairs.to_h["state"]
  end

  # build_redirect_uri merges into whatever query the registered
  # redirect_uri already carries. Appending iss must not drop the
  # client's own parameters, and must not drop code/state either.
  test "authorization response preserves the client's own query params alongside iss" do
    redirect_with_query = "https://claude.ai/callback?tenant=acme"
    client = register_client(redirect_uris: [ redirect_with_query ])
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: redirect_with_query,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      state: "xyz",
      resource: RESOURCE_A
    }
    assert_response :redirect

    returned = URI.decode_www_form(URI.parse(response.location).query).to_h
    assert_equal "acme", returned["tenant"], "client's own redirect_uri query param was dropped"
    assert_equal "xyz", returned["state"]
    assert returned["code"].present?
    assert returned["iss"].present?
  end

  test "authorize without sign-in returns 401 when login_path unset" do
    client = register_client
    get "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256"
    }
    assert_response :unauthorized
  end

  test "authorize rejects unregistered redirect_uri for known client" do
    client = register_client(redirect_uris: [ CLIENT_REDIRECT ])
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: "https://attacker.test/callback",
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE_A
    }
    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_equal "invalid_request", body["error"]
    assert_match(/redirect_uri/, body["error_description"])
  end

  test "authorize rejects non-https redirect_uri" do
    sign_in @user
    # A non-loopback http redirect is rejected at registration (DCR), so
    # register a valid loopback client, then attempt a plain-http public
    # host at authorize — the authorize endpoint re-validates the scheme
    # independently of what the client registered.
    client = register_client(redirect_uris: [ "http://localhost:8765/cb" ])
    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: "http://attacker.test/callback",
      code_challenge: @challenge,
      code_challenge_method: "S256"
    }
    assert_response :bad_request
    assert_equal "invalid_request", JSON.parse(response.body)["error"]
  end

  test "authorize allows http loopback redirect_uri for a registered client" do
    client = register_client(redirect_uris: [ "http://localhost:8765/cb" ])
    sign_in @user
    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: "http://localhost:8765/cb",
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE_A
    }
    assert_response :redirect
  end

  test "authorize rejects a request with no client_id (OAuth 2.1 requires it)" do
    sign_in @user
    post "/oauth/authorize", params: {
      response_type: "code",
      redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE_A
    }
    assert_response :bad_request
    assert_equal "invalid_request", JSON.parse(response.body)["error"]
    assert_match(/client_id/, JSON.parse(response.body)["error_description"])
  end

  test "token exchange rejects wrong PKCE verifier" do
    client = register_client
    sign_in @user
    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE_A
    }
    code = URI.decode_www_form(URI.parse(response.location).query).to_h["code"]

    post "/oauth/token", params: {
      grant_type: "authorization_code",
      code: code,
      client_id: client["client_id"],
      code_verifier: "wrong-verifier",
      resource: RESOURCE_A
    }
    assert_response :bad_request
    assert_equal "invalid_grant", JSON.parse(response.body)["error"]
  end

  test "token exchange rejects mismatched resource (RFC 8707)" do
    client = register_client
    sign_in @user
    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE_A
    }
    code = URI.decode_www_form(URI.parse(response.location).query).to_h["code"]

    post "/oauth/token", params: {
      grant_type: "authorization_code",
      code: code,
      client_id: client["client_id"],
      code_verifier: @verifier,
      resource: RESOURCE_B
    }
    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_equal "invalid_target", body["error"]
  end

  test "authorize rejects non-URI resource parameter (RFC 8707 absolute URI)" do
    sign_in @user
    [ "javascript:alert(1)", "not a uri", "data:text/html,<h1>x", "/relative/path", "ftp://example.com/x" ].each do |bad_resource|
      post "/oauth/authorize", params: {
        response_type: "code",
        client_id: "test-client",
        redirect_uri: CLIENT_REDIRECT,
        code_challenge: @challenge,
        code_challenge_method: "S256",
        resource: bad_resource
      }
      assert_response :bad_request, "expected reject for resource=#{bad_resource.inspect}"
      assert_equal "invalid_target", JSON.parse(response.body)["error"]
    end
  end

  test "authorize rejects resource with URL fragment (RFC 8707)" do
    sign_in @user
    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: "test-client",
      redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: "https://app.test/mcp#fragment"
    }
    assert_response :bad_request
    assert_equal "invalid_target", JSON.parse(response.body)["error"]
  end

  test "revoke endpoint always returns 200 (RFC 7009)" do
    # Unknown token still 200
    post "/oauth/revoke", params: { token: "nonexistent" }
    assert_response :ok

    # Real token gets revoked
    client = register_client
    sign_in @user
    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client["client_id"],
      redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE_A
    }
    code = URI.decode_www_form(URI.parse(response.location).query).to_h["code"]
    post "/oauth/token", params: {
      grant_type: "authorization_code",
      code: code,
      client_id: client["client_id"],
      code_verifier: @verifier,
      resource: RESOURCE_A
    }
    raw_token = JSON.parse(response.body)["access_token"]

    post "/oauth/revoke", params: { token: raw_token }
    assert_response :ok
    assert_nil Hitch::AccessToken.find_by_token(raw_token)
  end

  test "malformed revocation token shapes remain no-oracle 200 without lookup" do
    lookup = ->(*) { flunk "malformed revocation input must not reach token lookup" }

    stub_class_method(Hitch::AccessToken, :find_by_token, lookup) do
      post "/oauth/revoke", params: { token: { value: "nested" } }
      assert_response :ok

      post "/oauth/revoke", params: "token=one&token=two",
        headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
      assert_response :ok

      post "/oauth/revoke?token=query", params: "",
        headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
      assert_response :ok
    end
  end

  test "CORS preflight returns 204 with allowed-origin headers for claude.ai" do
    process :options, "/oauth/token", headers: {
      "Origin" => "https://claude.ai",
      "Access-Control-Request-Method" => "POST"
    }
    assert_response :no_content
    assert_equal "https://claude.ai", response.headers["Access-Control-Allow-Origin"]
  end

  test "CORS headers set on token endpoint when Origin allowed" do
    post "/oauth/token",
      params: { grant_type: "authorization_code", code: "x", code_verifier: "y" },
      headers: { "Origin" => "https://claude.ai" }
    assert_equal "https://claude.ai", response.headers["Access-Control-Allow-Origin"]
  end

  test "CORS headers not set when Origin is foreign" do
    post "/oauth/token",
      params: { grant_type: "authorization_code", code: "x", code_verifier: "y" },
      headers: { "Origin" => "https://attacker.test" }
    assert_nil response.headers["Access-Control-Allow-Origin"]
  end
end
