# frozen_string_literal: true

require "test_helper"

class Hitch::ClientIdMetadataTest < ActiveSupport::TestCase
  CIMD = Hitch::ClientIdMetadata
  DOC_URL = "https://client.example/metadata.json"

  setup do
    Hitch.reset_configuration!
    Hitch.configure { |c| c.client_id_metadata_enabled = true }
    @cache = Rails.cache
    # The test environment may use a null store, which would make every
    # cache assertion below vacuously pass.
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @cache
    Hitch.reset_configuration!
  end

  # --- reference? -----------------------------------------------------

  test "an https client_id is a CIMD reference only when the host opted in" do
    assert CIMD.reference?(DOC_URL)

    Hitch.configure { |c| c.client_id_metadata_enabled = false }
    assert_not CIMD.reference?(DOC_URL),
      "CIMD must stay inert until enabled — otherwise turning the feature off wouldn't close the outbound-fetch surface"
  end

  test "opaque DCR client_ids are never mistaken for CIMD references" do
    [
      SecureRandom.uuid, "", nil, "not a url", "http://client.example/doc.json",
      "ftp://client.example/doc.json", "javascript:alert(1)", "//client.example/doc.json",
      "https://", "https:///path"
    ].each do |value|
      assert_not CIMD.reference?(value), "#{value.inspect} must not be treated as a metadata document URL"
    end
  end

  # --- SSRF address vetting -------------------------------------------

  test "non-public addresses are refused" do
    blocked = %w[
      127.0.0.1 0.0.0.0 10.1.2.3 172.16.5.4 192.168.1.1 169.254.169.254
      100.64.0.1 192.0.2.5 198.18.0.1 224.0.0.1 240.0.0.1 255.255.255.255
      ::1 :: fe80::1 fc00::1 fd12:3456::1 ff02::1 2001:db8::1
    ]
    blocked.each do |address|
      assert_nil CIMD.send(:safe_address, address),
        "#{address} is not a public destination — resolving to it would make the authorize endpoint a proxy into a private network"
    end
  end

  test "public addresses are accepted" do
    %w[8.8.8.8 1.1.1.1 93.184.216.34 2606:2800:220:1:248:1893:25c8:1946].each do |address|
      assert_equal address, CIMD.send(:safe_address, address)
    end
  end

  # 169.254.169.254 is the cloud instance metadata endpoint — the single
  # most valuable SSRF target on any hosted deployment.
  test "the cloud metadata address is refused even via a hostname" do
    stub_class_method(Resolv, :getaddresses, ->(_host) { [ "169.254.169.254" ] }) do
      assert_nil CIMD.send(:safe_address, "metadata.attacker.example")
    end
  end

  # A name answering with one public and one private address is the
  # signature of a rebinding attempt; cherry-picking the public one would
  # defeat the check entirely.
  test "a name resolving to any non-public address is refused wholesale" do
    stub_class_method(Resolv, :getaddresses, ->(_host) { [ "93.184.216.34", "127.0.0.1" ] }) do
      assert_nil CIMD.send(:safe_address, "split.attacker.example")
    end
  end

  test "a name that resolves to nothing is refused" do
    stub_class_method(Resolv, :getaddresses, ->(_host) { [] }) do
      assert_nil CIMD.send(:safe_address, "nxdomain.example")
    end
  end

  # --- document validation --------------------------------------------

  def build(body, url: DOC_URL) = CIMD.send(:build_document, url, body)

  test "a valid document yields redirect_uris and a client name" do
    doc = build({ client_id: DOC_URL, client_name: "Example", redirect_uris: [ "https://client.example/cb" ] }.to_json)
    assert_equal DOC_URL, doc.client_id
    assert_equal "Example", doc.client_name
    assert_equal [ "https://client.example/cb" ], doc.redirect_uris
  end

  # The binding that makes CIMD safe at all: without it, one hosted
  # document could impersonate any other client by listing that client's
  # redirect_uris and having codes delivered there.
  test "a document naming a different client_id is refused" do
    doc = build({ client_id: "https://victim.example/metadata.json", redirect_uris: [ "https://a.test/cb" ] }.to_json)
    assert_nil doc
  end

  test "a document with a missing, non-string, or mismatched client_id is refused" do
    [ nil, 42, [ DOC_URL ], "#{DOC_URL}/", DOC_URL.upcase ].each do |value|
      assert_nil build({ client_id: value, redirect_uris: [ "https://a.test/cb" ] }.to_json),
        "client_id #{value.inspect} must not satisfy the self-binding check"
    end
  end

  test "a document without usable redirect_uris is refused" do
    [ nil, [], [ 1, 2 ], "https://a.test/cb" ].each do |value|
      assert_nil build({ client_id: DOC_URL, redirect_uris: value }.to_json)
    end
  end

  test "a document with an absurd number of redirect_uris is refused" do
    many = Array.new(CIMD::MAX_REDIRECT_URIS + 1) { |i| "https://client.example/cb#{i}" }
    assert_nil build({ client_id: DOC_URL, redirect_uris: many }.to_json)
  end

  test "a document that is not a JSON object is refused" do
    [ "[]", "\"a string\"", "42", "null" ].each do |body|
      assert_nil build(body)
    end
  end

  test "a non-string client_name is dropped rather than failing the document" do
    doc = build({ client_id: DOC_URL, client_name: { evil: true }, redirect_uris: [ "https://a.test/cb" ] }.to_json)
    assert_not_nil doc
    assert_nil doc.client_name
  end

  # --- caching ---------------------------------------------------------

  test "a resolved document is cached rather than refetched" do
    calls = 0
    document = CIMD::Document.new(client_id: DOC_URL, client_name: "X", redirect_uris: [ "https://a.test/cb" ])

    stub_class_method(CIMD, :fetch_and_validate, ->(_id) { calls += 1; document }) do
      3.times { assert_equal [ "https://a.test/cb" ], CIMD.resolve(DOC_URL).redirect_uris }
    end
    assert_equal 1, calls, "a cached document must not trigger a second outbound fetch"
  end

  # Without negative caching, an attacker supplies a client_id pointing at
  # a slow or hostile host and gets one outbound request per inbound
  # authorize request — the authorization server becomes the amplifier.
  test "a failed resolution is cached too" do
    calls = 0
    stub_class_method(CIMD, :fetch_and_validate, ->(_id) { calls += 1; nil }) do
      3.times { assert_nil CIMD.resolve(DOC_URL) }
    end
    assert_equal 1, calls, "a failing document must not trigger an outbound fetch per authorize request"
  end

  test "resolve returns nil without fetching when the feature is disabled" do
    Hitch.configure { |c| c.client_id_metadata_enabled = false }
    stub_class_method(CIMD, :fetch_and_validate, ->(_id) { flunk "must not fetch while disabled" }) do
      assert_nil CIMD.resolve(DOC_URL)
    end
  end

  test "resolve refuses a URL carrying userinfo or a fragment" do
    stub_class_method(CIMD, :safe_address, ->(_host) { flunk "must reject on URL shape before any DNS lookup" }) do
      assert_nil CIMD.resolve("https://user:pw@client.example/doc.json")
      assert_nil CIMD.resolve("https://client.example/doc.json#frag")
    end
  end
end
