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
    %w[8.8.8.8 1.1.1.1 93.184.216.34 2606:2800:220:1:248:1893:25c8:1946 2a00:1450:4009:81f::200e].each do |address|
      assert_equal address, CIMD.send(:safe_address, address)
    end
  end

  # IPv6 is an allowlist precisely because these exist. A denylist has to
  # anticipate every way an address can name somewhere it shouldn't —
  # tunnelling formats that embed an arbitrary IPv4 destination, NAT64
  # prefixes that are network-specific by RFC, deprecated site-local
  # space — and cannot be complete. Only global unicast gets through.
  test "IPv6 addresses outside global unicast are refused" do
    {
      "::127.0.0.1" => "IPv4-compatible (RFC 4291 §2.5.5.1)",
      "::ffff:127.0.0.1" => "IPv4-mapped — IPAddr reports this as ipv6?, so it must be caught by the v6 path",
      "2002:7f00:1::" => "6to4, embedding 127.0.0.1",
      "2001:0:1234::" => "Teredo",
      "fec0::1" => "deprecated site-local",
      "64:ff9b::7f00:1" => "well-known NAT64",
      "64:ff9b:1::7f00:1" => "local-use NAT64 (RFC 8215) — network-specific, unknowable to a denylist",
      "::1" => "loopback",
      "::" => "unspecified",
      "fe80::1" => "link-local",
      "fc00::1" => "unique-local",
      "ff02::1" => "multicast",
      "5f00::1" => "SRv6 (RFC 9602)"
    }.each do |address, why|
      assert_nil CIMD.send(:safe_address, address), "#{address} (#{why}) must be refused"
    end
  end

  test "special-purpose blocks carved out of global unicast are refused" do
    {
      "2001:db8::1" => "documentation",
      "2001:10::1" => "ORCHID",
      "2001:20::1" => "ORCHIDv2",
      "3fff::1" => "documentation (RFC 9637)"
    }.each do |address, why|
      assert_nil CIMD.send(:safe_address, address), "#{address} (#{why}) is inside 2000::/3 but must still be refused"
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

  # --- the wire itself -------------------------------------------------
  #
  # Everything above stubs the network. These drive read_document over a
  # real socket, because the interesting failures live in how Net::HTTP is
  # called, not in the logic around it: calling #request WITHOUT a block
  # buffers the whole body before returning, which both defeats the size
  # cap and makes a later #read_body raise "called twice" — leaving the
  # feature permanently inert behind a blanket rescue. Plain HTTP here;
  # TLS and address pinning are configured in build_connection, which
  # these deliberately bypass to isolate the request/stream contract.

  def serve(handler)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        socket = server.accept
        begin
          # Drain the request head: read lines until the blank one that
          # terminates the headers, then respond.
          while (line = socket.gets)
            break if line.strip.empty?
          end
          handler.call(socket)
        rescue StandardError
          nil
        ensure
          socket.close rescue nil
        end
      end
    rescue StandardError
      nil
    end
    yield server.addr[1]
  ensure
    server&.close rescue nil
    thread&.kill
  end

  def read_over_socket(port, path = "/doc.json")
    uri = URI.parse("http://127.0.0.1:#{port}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 2
    http.read_timeout = 3
    http.max_retries = 0
    http.start { |connection| CIMD.send(:read_document, connection, uri) }
  end

  # build_connection is where the address pin, TLS verification and
  # retry suppression live, and the socket tests below deliberately
  # bypass it — so without this every one of those settings could be
  # deleted with the suite still green. That is the same coverage gap
  # that let the streaming bug ship, so it gets pinned explicitly.
  test "the connection is pinned to the vetted address with TLS verified" do
    uri = URI.parse(DOC_URL)
    http = CIMD.send(:build_connection, uri, "93.184.216.34")

    assert_equal "93.184.216.34", http.ipaddr,
      "the socket must go to the address that was actually vetted, not to a fresh lookup"
    assert_equal "client.example", http.address,
      "the hostname must survive for SNI and certificate verification"
    assert http.use_ssl?
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
    assert_equal 0, http.max_retries,
      "a retry would replay the request and double every time budget"
    assert_equal CIMD::OPEN_TIMEOUT, http.open_timeout
    assert_equal CIMD::READ_TIMEOUT, http.read_timeout
    assert_not http.proxy?,
      "an ambient http_proxy would reach the destination from the proxy's egress instead of this app's"
  end

  test "a valid document is actually read off the wire" do
    body = { client_id: DOC_URL, redirect_uris: [ "https://client.example/cb" ] }.to_json
    handler = lambda do |socket|
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    end

    serve(handler) do |port|
      assert_equal body, read_over_socket(port),
        "the document must come back intact — if this returns nil the feature is inert no matter how correct the surrounding logic is"
    end
  end

  # The cap has to hold when the sender omits Content-Length, because the
  # sender is the attacker. Asserts both that the read is refused AND that
  # the stream was abandoned early, since buffering gigabytes and then
  # rejecting them is the failure mode being guarded against.
  test "an oversized body is abandoned mid-stream rather than buffered" do
    chunk = "x" * 64_000
    intended = 200 * chunk.bytesize
    counter = [ 0 ]
    mutex = Mutex.new

    handler = lambda do |socket|
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n")
      200.times do
        socket.write("#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n")
        mutex.synchronize { counter[0] += chunk.bytesize }
      end
      socket.write("0\r\n\r\n")
    end

    serve(handler) do |port|
      assert_nil read_over_socket(port), "a body past MAX_BYTES must be refused"
      sent = mutex.synchronize { counter[0] }
      assert_operator sent, :<, intended / 4,
        "the connection must be dropped once the cap is passed — #{sent} of #{intended} bytes were accepted"
    end
  end

  test "a non-200 response is refused" do
    [ "404 Not Found", "302 Found", "500 Internal Server Error" ].each do |status|
      handler = ->(socket) { socket.write("HTTP/1.1 #{status}\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}") }
      serve(handler) { |port| assert_nil read_over_socket(port), "#{status} must not be treated as a document" }
    end
  end

  test "a declared Content-Length over the cap is refused before reading" do
    handler = lambda do |socket|
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: #{CIMD::MAX_BYTES + 1}\r\nConnection: close\r\n\r\n")
      socket.write("x" * (CIMD::MAX_BYTES + 1))
    end
    serve(handler) { |port| assert_nil read_over_socket(port) }
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

  # Keyed by URL alone, the negative cache is defeated by a trailing
  # ?n=1, ?n=2 — each a distinct key and each a valid CIMD reference.
  # Keying the unreachable-host case by host closes that: a host nothing
  # can connect to is not retried however the URL is dressed up.
  #
  # This is deliberately narrower than "cache every failure by host".
  # See the co-tenant test above: a host that ANSWERS and merely serves
  # an unusable document must not have its other documents blocked, so
  # the query-string bypass does survive for that case. Negative caching
  # raises the cost of amplification here; it is not a complete guard,
  # and a rate or concurrency cap on outbound fetches is the real
  # backstop.
  test "an unreachable host is not refetched under a different path or query" do
    calls = 0
    stub_class_method(CIMD, :fetch_and_validate, ->(_id) { calls += 1; CIMD::HOST_FAILURE }) do
      assert_nil CIMD.resolve("https://evil.example/doc.json")
      assert_nil CIMD.resolve("https://evil.example/doc.json?n=1")
      assert_nil CIMD.resolve("https://evil.example/doc.json?n=2")
      assert_nil CIMD.resolve("https://evil.example/other/path.json")
    end
    assert_equal 1, calls, "appending a query string must not buy another connection to a host that never answered"
  end

  # One domain hosting many client documents is the normal CIMD shape.
  # A 404 or a malformed document on one of them says nothing about its
  # neighbours — blocking them would let any signed-in user hold an
  # entire CIMD-hosting domain offline by requesting one bogus URL on it
  # once a minute.
  test "a document-level failure does not block other documents on the same host" do
    good = CIMD::Document.new(client_id: "https://shared.example/b.json", redirect_uris: [ "https://a.test/cb" ])
    stub_class_method(CIMD, :fetch_and_validate, ->(id) { id.end_with?("a.json") ? nil : good }) do
      assert_nil CIMD.resolve("https://shared.example/a.json")
      assert_not_nil CIMD.resolve("https://shared.example/b.json"),
        "a co-tenant document must still resolve after a sibling failed"
    end
  end

  test "a host that does not answer at all does block its other documents" do
    calls = 0
    stub_class_method(CIMD, :fetch_and_validate, ->(_id) { calls += 1; CIMD::HOST_FAILURE }) do
      assert_nil CIMD.resolve("https://dead.example/a.json")
      assert_nil CIMD.resolve("https://dead.example/b.json")
    end
    assert_equal 1, calls, "nothing answered at that host — its other documents are not worth a second connection"
  end

  test "a trailing dot is the same host for negative-caching purposes" do
    calls = 0
    stub_class_method(CIMD, :fetch_and_validate, ->(_id) { calls += 1; CIMD::HOST_FAILURE }) do
      assert_nil CIMD.resolve("https://dead.example/a.json")
      assert_nil CIMD.resolve("https://dead.example./a.json")
      assert_nil CIMD.resolve("https://DEAD.example/a.json")
    end
    assert_equal 1, calls, "evil.example and evil.example. are one DNS name and must share one key"
  end

  # A URL rejected on shape never touches the network, so caching the
  # rejection buys nothing and lets a caller fill a shared cache — and
  # evict the host app's own entries — without sending a packet.
  test "a shape rejection writes no cache entry" do
    before = Rails.cache.instance_variable_get(:@data)&.size.to_i
    5.times { |i| assert_nil CIMD.resolve("https://client.example:8443/doc#{i}.json") }
    after = Rails.cache.instance_variable_get(:@data)&.size.to_i
    assert_equal before, after, "rejecting on port alone must not populate the cache"
  end

  test "a failing host does not poison an unrelated host" do
    hosts = []
    stub_class_method(CIMD, :fetch_and_validate, ->(id) { hosts << URI.parse(id).host; nil }) do
      CIMD.resolve("https://evil.example/doc.json")
      CIMD.resolve("https://good.example/doc.json")
    end
    assert_equal [ "evil.example", "good.example" ], hosts
  end

  # An arbitrary port would let a caller drive TLS connections to any
  # host:port from the authorization server's egress address — the usual
  # way around a third party's source-IP allowlist.
  test "resolve refuses a non-443 port" do
    stub_class_method(CIMD, :safe_address, ->(_host) { flunk "must reject on port before any DNS lookup" }) do
      assert_nil CIMD.resolve("https://client.example:8443/doc.json")
      assert_nil CIMD.resolve("https://client.example:22/doc.json")
    end
  end

  test "resolve refuses a URL carrying userinfo or a fragment" do
    stub_class_method(CIMD, :safe_address, ->(_host) { flunk "must reject on URL shape before any DNS lookup" }) do
      assert_nil CIMD.resolve("https://user:pw@client.example/doc.json")
      assert_nil CIMD.resolve("https://client.example/doc.json#frag")
    end
  end
end
