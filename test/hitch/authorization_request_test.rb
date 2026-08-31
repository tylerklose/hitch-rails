# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "securerandom"

# First direct unit coverage of the authorize flow's HTTP-free core; the
# integration suites keep pinning the wire.
class Hitch::AuthorizationRequestTest < ActiveSupport::TestCase
  RESOURCE = "https://dummy.test/mcp"
  REDIRECT = "https://claude.ai/api/mcp/auth_callback"
  CIMD_URL = "https://client.example/oauth/metadata.json"

  setup do
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |configuration|
      configuration.resource_uri = RESOURCE
      configuration.supported_scopes = %w[mcp invoke]
    end
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest("verifier" * 8), padding: false)
  end

  teardown do
    Hitch.reset_configuration!
    Hitch::Client.delete_all
  end

  test "a registered request is valid, carries the canonical resource, and freezes params" do
    client = register_client
    request = build_request(client_id: client.client_id)

    assert_predicate request, :valid?
    assert_nil request.error
    assert_equal RESOURCE, request.resource
    assert_equal RESOURCE, request.params[:resource]
    assert_predicate request.params, :frozen?
  end

  test "the parameter validation matrix names each failure" do
    client = register_client
    {
      { response_type: nil } => [ "invalid_request", "response_type is required" ],
      { response_type: "token" } => [ "unsupported_response_type", "response_type must be code" ],
      { client_id: nil } => [ "invalid_request", "client_id is required" ],
      { redirect_uri: nil } => [ "invalid_request", "redirect_uri is required" ],
      { redirect_uri: "http://remote.example/cb" } => [ "invalid_request", "Invalid redirect_uri" ],
      { code_challenge: nil } => [ "invalid_request", "code_challenge is required" ],
      { code_challenge: "short" } =>
        [ "invalid_request", "code_challenge must be a 43-character S256 value" ],
      { code_challenge_method: "plain" } =>
        [ "invalid_request", "code_challenge_method must be S256" ],
      { resource: nil } => [ "invalid_target", "resource is required" ],
      { resource: "https://elsewhere.test/mcp" } =>
        [ "invalid_target", "resource does not identify this MCP server" ]
    }.each do |overrides, (code, description)|
      request = build_request(client_id: client.client_id, **overrides)

      refute_predicate request, :valid?, overrides.inspect
      assert_equal code, request.error.code, overrides.inspect
      assert_equal description, request.error.description, overrides.inspect
      assert_equal :bad_request, request.error.status, overrides.inspect
    end
  end

  test "unknown clients fail with the scheme's own guidance" do
    request = build_request(client_id: SecureRandom.uuid)
    refute_predicate request, :valid?
    assert_equal "invalid_client", request.error.code
    assert_equal "Unknown client_id — register via /oauth/register first", request.error.description

    Hitch.configure { |configuration| configuration.client_id_metadata_enabled = true }
    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { nil }) do
      request = build_request(client_id: CIMD_URL)
      refute_predicate request, :valid?
      assert_equal "invalid_client", request.error.code
      assert_equal "Could not resolve a client metadata document at that client_id",
        request.error.description
    end
  end

  test "a principal that cannot be counted drives no metadata fetch" do
    # The per-actor fetch limit is the bound on amplification; with no
    # actor to count, the fetch must not happen at all.
    Hitch.configure { |configuration| configuration.client_id_metadata_enabled = true }
    unidentifiable = Struct.new(:id).new(nil)
    request = Hitch::AuthorizationRequest.new({ client_id: CIMD_URL }, principal: unidentifiable)
    fetch_forbidden = ->(*, **) { raise "fetched on behalf of an uncountable principal" }

    stub_class_method(Hitch::ClientIdMetadata, :resolve, fetch_forbidden) do
      assert_nil request.client
    end
  end

  test "an unregistered redirect_uri is refused; loopback matches port-agnostically" do
    client = register_client(redirect_uris: [ REDIRECT, "http://127.0.0.1:7777/cb" ])

    mismatched = build_request(client_id: client.client_id, redirect_uri: "https://claude.ai/other")
    refute_predicate mismatched, :valid?
    assert_equal "redirect_uri not registered for this client", mismatched.error.description

    ephemeral_port = build_request(client_id: client.client_id, redirect_uri: "http://127.0.0.1:9999/cb")
    assert_predicate ephemeral_port, :valid?
  end

  test "a CIMD document's redirect_uris are filtered by the gem's URI policy" do
    Hitch.configure { |configuration| configuration.client_id_metadata_enabled = true }
    document = Hitch::ClientIdMetadata::Document.new(
      client_id: CIMD_URL,
      client_name: "Doc Client",
      redirect_uris: [ "http://remote.example/cb" ]
    )

    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { document }) do
      request = build_request(client_id: CIMD_URL, redirect_uri: REDIRECT)
      refute_predicate request, :valid?
      assert_equal "client has no usable redirect_uris", request.error.description
    end
  end

  test "a CIMD grokbot URI is usable only when the document host is a Grok voucher" do
    Hitch.configure { |configuration| configuration.client_id_metadata_enabled = true }
    native = "grokbot://mcp/oauth/callback"
    hostile = Hitch::ClientIdMetadata::Document.new(
      client_id: CIMD_URL, client_name: "Doc", redirect_uris: [ native ]
    )
    grok = Hitch::ClientIdMetadata::Document.new(
      client_id: "https://grok.com/oauth/client-metadata.json",
      client_name: "Doc",
      redirect_uris: [ native ]
    )

    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { hostile }) do
      request = build_request(client_id: CIMD_URL, redirect_uri: native)
      refute_predicate request, :valid?
      assert_equal "client has no usable redirect_uris", request.error.description
    end
    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { grok }) do
      request = build_request(client_id: grok.client_id, redirect_uri: native)
      assert_predicate request, :valid?
    end
  end

  test "scopes clamp to the supported allowlist and never issue empty" do
    client = register_client
    assert_equal "mcp", build_request(client_id: client.client_id, scope: "mcp admin").granted_scopes
    assert_equal "mcp invoke",
      build_request(client_id: client.client_id, scope: "mcp invoke").granted_scopes
    assert_equal "mcp", build_request(client_id: client.client_id, scope: "admin").granted_scopes
    assert_equal "mcp", build_request(client_id: client.client_id, scope: nil).granted_scopes
  end

  test "redirect_uri_for strips response parameters, keeps the rest, and always carries iss" do
    registered = "#{REDIRECT}?keep=1&code=stale&error=stale&iss=stale"
    request = build_request(client_id: "unused", redirect_uri: registered)

    redirect = URI.parse(request.redirect_uri_for(code: "fresh", state: "abc"))
    query = URI.decode_www_form(redirect.query)

    assert_includes query, [ "keep", "1" ]
    assert_includes query, [ "code", "fresh" ]
    assert_includes query, [ "state", "abc" ]
    assert_includes query, [ "iss", "https://dummy.test" ]
    assert_equal 1, query.count { |key, _| key == "code" }
    refute query.any? { |key, _| key == "error" }
    assert_equal 1, query.count { |key, _| key == "iss" }
  end

  test "display name derives from the verified redirect host, never the declared name" do
    client = register_client(client_name: "<script>Trusted Bank</script>")
    request = build_request(client_id: client.client_id)

    assert_equal "Claude", request.display_client_name
    assert_equal "<script>Trusted Bank</script>", request.audit_client_name

    unknown_host = build_request(client_id: client.client_id, redirect_uri: "https://tool.example/cb")
    assert_equal "tool.example", unknown_host.display_client_name
  end

  test "a native redirect is labelled by the voucher, not the URI host" do
    Hitch.configure { |configuration| configuration.client_id_metadata_enabled = true }
    grok = Hitch::ClientIdMetadata::Document.new(
      client_id: "https://grok.com/oauth/client-metadata.json",
      client_name: "Trusted Bank",
      redirect_uris: [ "grokbot://mcp/oauth/callback" ]
    )
    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { grok }) do
      request = build_request(
        client_id: grok.client_id,
        redirect_uri: "grokbot://mcp/oauth/callback"
      )
      assert_equal "Grok", request.display_client_name
      assert_equal "grok.com", request.redirect_host
    end

    operator = Hitch::Client.register_confidential!(
      client_id: "operator-native",
      client_name: "Claude",
      redirect_uris: [ "grokbot://mcp/oauth/callback" ],
      operator_registered: true
    ).client
    native = build_request(client_id: operator.client_id, redirect_uri: "grokbot://mcp/oauth/callback")
    assert_equal "grokbot", native.display_client_name
    assert_equal "grokbot", native.redirect_host
  end

  test "client_names is host-configurable and matches in order with case/when semantics" do
    Hitch.configure do |configuration|
      configuration.client_names = { "tool.example" => "My Tool", /\Atool\./ => "Shadowed" }
    end

    assert_equal "My Tool",
      build_request(client_id: "x", redirect_uri: "https://tool.example/cb").display_client_name
    assert_equal "other.example",
      build_request(client_id: "x", redirect_uri: "https://other.example/cb").display_client_name

    assert_raises(ArgumentError) { Hitch.configure { |c| c.client_names = { 7 => "label" } } }
    assert_raises(ArgumentError) { Hitch.configure { |c| c.client_names = { "host" => :label } } }
    assert_raises(ArgumentError) { Hitch.configure { |c| c.client_names = [ "host" ] } }
  end

  test "localhost-only warning fires only for all-loopback CIMD clients" do
    Hitch.configure { |configuration| configuration.client_id_metadata_enabled = true }
    loopback_only = Hitch::ClientIdMetadata::Document.new(
      client_id: CIMD_URL, client_name: "Local", redirect_uris: [ "http://localhost:9000/cb" ]
    )
    mixed = Hitch::ClientIdMetadata::Document.new(
      client_id: CIMD_URL, client_name: "Mixed",
      redirect_uris: [ "http://localhost:9000/cb", REDIRECT ]
    )

    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { loopback_only }) do
      assert_predicate build_request(client_id: CIMD_URL), :localhost_only_client?
    end
    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { mixed }) do
      refute_predicate build_request(client_id: CIMD_URL), :localhost_only_client?
    end

    dcr = register_client
    refute_predicate build_request(client_id: dcr.client_id), :localhost_only_client?
  end

  test "client resolution happens once and carries the per-principal actor" do
    Hitch.configure { |configuration| configuration.client_id_metadata_enabled = true }
    principal = Struct.new(:id).new(42)
    calls = []
    resolver = lambda do |client_id, actor: nil|
      calls << [ client_id, actor ]
      nil
    end

    stub_class_method(Hitch::ClientIdMetadata, :resolve, resolver) do
      request = build_request(client_id: CIMD_URL, principal: principal)
      2.times { request.client }
      assert_equal [ [ CIMD_URL, "#{principal.class.name}:42" ] ], calls
    end
  end

  test "deny is a POST decision, not a default" do
    refute_predicate build_request(client_id: "any"), :deny?
    assert_predicate build_request(client_id: "any", decision: "deny"), :deny?
    refute_predicate build_request(client_id: "any", decision: "approve"), :deny?
  end

  private

  def register_client(client_name: "Declared Name", redirect_uris: [ REDIRECT ])
    Hitch::Client.register!(
      client_id: SecureRandom.uuid,
      client_name: client_name,
      redirect_uris: redirect_uris
    )
  end

  def build_request(principal: Struct.new(:id).new(7), **overrides)
    Hitch::AuthorizationRequest.new(
      {
        response_type: "code",
        redirect_uri: REDIRECT,
        scope: "mcp",
        state: "state-1",
        code_challenge: @challenge,
        code_challenge_method: "S256",
        resource: RESOURCE
      }.merge(overrides),
      principal: principal
    )
  end
end
