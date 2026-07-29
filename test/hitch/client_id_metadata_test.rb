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
    # Both of these are process-wide and nothing else resets them. Left
    # alone, a test that fails mid-slot leaves every later CIMD test
    # failing closed, and one that spends a rate budget silently
    # throttles the next test using the same actor name — either way
    # reported as an unrelated cascade.
    CIMD.instance_variable_set(:@fetches_in_flight, 0)
    CIMD.instance_variable_set(:@rate_counts, {})
    CIMD.instance_variable_set(:@warned, {})
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

  # "The client_id URL MUST use the 'https' scheme and contain a path
  # component" — MCP 2026-07-28, Client Registration. A bare origin is
  # not a document URL, and treating it as one would trigger an outbound
  # fetch for something that can never be a valid reference.
  test "an https client_id without a path component is not a CIMD reference" do
    [ "https://client.example", "https://client.example/", "https://client.example?a=1" ].each do |value|
      assert_not CIMD.reference?(value), "#{value.inspect} has no path component"
    end

    assert CIMD.reference?("https://client.example/client.json")
    assert CIMD.reference?("https://client.example/oauth/client-metadata.json")
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
    doc = build({ client_id: "https://victim.example/metadata.json", client_name: "V", redirect_uris: [ "https://a.test/cb" ] }.to_json)
    assert_nil doc
  end

  test "a document with a missing, non-string, or mismatched client_id is refused" do
    [ nil, 42, [ DOC_URL ], "#{DOC_URL}/", DOC_URL.upcase ].each do |value|
      assert_nil build({ client_id: value, client_name: "N", redirect_uris: [ "https://a.test/cb" ] }.to_json),
        "client_id #{value.inspect} must not satisfy the self-binding check"
    end
  end

  test "a document without usable redirect_uris is refused" do
    [ nil, [], [ 1, 2 ], "https://a.test/cb" ].each do |value|
      assert_nil build({ client_id: DOC_URL, client_name: "N", redirect_uris: value }.to_json)
    end
  end

  test "a document with an absurd number of redirect_uris is refused" do
    many = Array.new(CIMD::MAX_REDIRECT_URIS + 1) { |i| "https://client.example/cb#{i}" }
    assert_nil build({ client_id: DOC_URL, client_name: "N", redirect_uris: many }.to_json)
  end

  test "a document that is not a JSON object is refused" do
    [ "[]", "\"a string\"", "42", "null" ].each do |body|
      assert_nil build(body)
    end
  end

  # "The metadata document MUST include at least the following
  # properties: client_id, client_name, redirect_uris" — MCP 2026-07-28,
  # Client Registration. Absent or non-string makes the document
  # invalid, rather than merely nameless.
  test "a document without a usable client_name is refused" do
    [ nil, "", { evil: true }, 42, [ "Name" ] ].each do |value|
      assert_nil build({ client_id: DOC_URL, client_name: value, redirect_uris: [ "https://a.test/cb" ] }.to_json),
        "client_name #{value.inspect} must fail the document"
    end
  end

  # --- fetch volume caps -----------------------------------------------
  #
  # Negative caching bounds repeat fetches of the SAME thing. Neither of
  # the tricks that defeat it changes who is asking or how many threads
  # are in use, which is what these two bound instead.

  test "concurrent fetches are capped, and the cap is released afterwards" do
    Hitch.configure { |c| c.client_id_metadata_max_concurrent_fetches = 2 }

    gate = Queue.new
    running = Queue.new
    outcomes = Queue.new

    stub_class_method(CIMD, :fetch_and_validate, lambda { |_id, *|
      running << :in
      gate.pop # hold the slot until the test lets go
      nil
    }) do
      holders = 2.times.map do |i|
        Thread.new { outcomes << [ :held, CIMD.resolve("https://client.example/hold#{i}.json") ] }
      end
      2.times { running.pop } # both slots genuinely occupied

      assert_equal 2, CIMD.fetches_in_flight
      # A third caller must be refused rather than queued — queueing is
      # what consumes the request thread this cap protects.
      assert_nil CIMD.resolve("https://client.example/third.json")

      2.times { gate << :go }
      holders.each(&:join)
    end

    assert_equal 0, CIMD.fetches_in_flight, "the cap must be released even though those fetches failed"
  end

  # A refusal on capacity says nothing about the URL or the host. Caching
  # it as a host failure would turn cap exhaustion into a way to poison a
  # legitimate host's entry for every other caller.
  test "a capacity refusal is never cached" do
    document = CIMD::Document.new(client_id: DOC_URL, client_name: "X", redirect_uris: [ "https://a.test/cb" ])

    stub_class_method(CIMD, :fetch_and_validate, ->(_id, *) { [ document, 3600 ] }) do
      Hitch.configure { |c| c.client_id_metadata_max_concurrent_fetches = 0 }
      assert_nil CIMD.resolve(DOC_URL), "no capacity, so no fetch"

      Hitch.configure { |c| c.client_id_metadata_max_concurrent_fetches = 4 }
      assert_not_nil CIMD.resolve(DOC_URL),
        "the earlier refusal must not have poisoned this URL or its host — a capacity refusal says nothing about either"
    end
  end

  # nil disables; 0 is honoured literally. Treating 0 as "disabled" would
  # make the most restrictive-looking setting the least restrictive one —
  # which is exactly the bug this test was written against.
  test "a nil concurrency cap disables the cap, and zero blocks every fetch" do
    document = CIMD::Document.new(client_id: DOC_URL, client_name: "X", redirect_uris: [ "https://a.test/cb" ])

    stub_class_method(CIMD, :fetch_and_validate, ->(_id, *) { [ document, 3600 ] }) do
      Hitch.configure { |c| c.client_id_metadata_max_concurrent_fetches = nil }
      assert_not_nil CIMD.resolve(DOC_URL)

      Rails.cache.clear
      Hitch.configure { |c| c.client_id_metadata_max_concurrent_fetches = 0 }
      assert_nil CIMD.resolve(DOC_URL)
    end
  end

  # The bypasses negative caching cannot close: a wildcard DNS record
  # gives unlimited distinct hosts, and a host answering 404 gives
  # unlimited distinct URLs. Neither changes the principal asking.
  test "fetches are rate limited per principal across distinct hosts and URLs" do
    Hitch.configure { |c| c.client_id_metadata_fetches_per_minute = 3 }
    calls = 0

    stub_class_method(CIMD, :fetch_and_validate, ->(_id, *) { calls += 1; nil }) do
      10.times { |i| CIMD.resolve("https://n#{i}.evil.example/doc.json", actor: "User:1") }
    end
    assert_equal 3, calls, "a wildcard DNS record must not buy unlimited outbound fetches"

    calls = 0
    stub_class_method(CIMD, :fetch_and_validate, ->(_id, *) { calls += 1; nil }) do
      10.times { |i| CIMD.resolve("https://responsive.example/doc.json?n=#{i}", actor: "User:2") }
    end
    assert_equal 3, calls, "distinct URLs on one responsive host must not either"
  end

  test "the rate limit is per principal, not global" do
    Hitch.configure { |c| c.client_id_metadata_fetches_per_minute = 2 }
    actors = []

    stub_class_method(CIMD, :fetch_and_validate, ->(id, *) { actors << id; nil }) do
      3.times { |i| CIMD.resolve("https://a.example/#{i}.json", actor: "User:1") }
      3.times { |i| CIMD.resolve("https://b.example/#{i}.json", actor: "User:2") }
    end
    assert_equal 4, actors.length, "one principal exhausting its budget must not throttle another"
  end

  # Cached resolutions cost nothing outbound, so charging them would make
  # a busy, correctly-configured server throttle itself.
  test "cache hits are not charged against the rate limit" do
    Hitch.configure { |c| c.client_id_metadata_fetches_per_minute = 2 }
    document = CIMD::Document.new(client_id: DOC_URL, client_name: "X", redirect_uris: [ "https://a.test/cb" ])
    calls = 0

    stub_class_method(CIMD, :fetch_and_validate, ->(_id, *) { calls += 1; [ document, 3600 ] }) do
      10.times { assert_not_nil CIMD.resolve(DOC_URL, actor: "User:1") }
    end
    assert_equal 1, calls
  end

  test "rate limiting is skipped without an actor or when disabled" do
    calls = 0
    stub_class_method(CIMD, :fetch_and_validate, ->(_id, *) { calls += 1; nil }) do
      Hitch.configure { |c| c.client_id_metadata_fetches_per_minute = 1 }
      3.times { |i| CIMD.resolve("https://x#{i}.example/d.json") } # no actor

      Hitch.configure { |c| c.client_id_metadata_fetches_per_minute = nil }
      3.times { |i| CIMD.resolve("https://y#{i}.example/d.json", actor: "User:9") }
    end
    assert_equal 6, calls
  end

  # Capacity is taken before the minute budget is charged. The other
  # order spends a token on a request that never sent a packet — so an
  # attacker holding the slots would drain every victim's own budget
  # while they retried, locking them out past the point where the slots
  # freed up.
  test "a capacity refusal does not spend the principal's rate budget" do
    Hitch.configure do |c|
      c.client_id_metadata_max_concurrent_fetches = 0
      c.client_id_metadata_fetches_per_minute = 3
    end
    5.times { |i| assert_nil CIMD.resolve("https://client.example/#{i}.json", actor: "User:1") }

    calls = 0
    Hitch.configure { |c| c.client_id_metadata_max_concurrent_fetches = 4 }
    stub_class_method(CIMD, :fetch_and_validate, ->(_id, *) { calls += 1; nil }) do
      3.times { |i| CIMD.resolve("https://client.example/after#{i}.json", actor: "User:1") }
    end
    assert_equal 3, calls, "the refused requests must not have spent the budget they never used"
  end

  # The docs say "nil disables". The obvious wrong guess at that is
  # `false`, whose #to_i does not exist — which raised NoMethodError
  # straight out of resolve and 500ed /oauth/authorize.
  #
  # Asserts the RESULTING BEHAVIOUR, not merely that nothing raised: an
  # earlier version of this test passed while Kernel.Integer quietly
  # truncated 2.5 to a working cap of 2, blessing exactly what its own
  # name said it rejected.
  test "a non-integer cap setting is treated as unset, not coerced" do
    [ false, true, "four", Object.new, 2.5, 0.9 ].each do |bad|
      Hitch.configure do |c|
        c.client_id_metadata_max_concurrent_fetches = bad
        c.client_id_metadata_fetches_per_minute = bad
      end
      assert_nil CIMD.send(:integer_setting, :client_id_metadata_max_concurrent_fetches),
        "#{bad.inspect} must be unset, never coerced to a working limit"
      assert_nil CIMD.send(:integer_setting, :client_id_metadata_fetches_per_minute)
    end

    # Strings are accepted, because settings often arrive from ENV.
    Hitch.configure { |c| c.client_id_metadata_fetches_per_minute = "7" }
    assert_equal 7, CIMD.send(:integer_setting, :client_id_metadata_fetches_per_minute)
  end

  # Parallel to the concurrency-zero test. The most restrictive-looking
  # value must not be the one that removes the protection.
  test "a rate limit of zero blocks every fetch, and nil disables the limit" do
    calls = 0
    stub_class_method(CIMD, :fetch_and_validate, ->(_id, *) { calls += 1; nil }) do
      Hitch.configure { |c| c.client_id_metadata_fetches_per_minute = 0 }
      3.times { |i| CIMD.resolve("https://z#{i}.example/d.json", actor: "User:1") }
      assert_equal 0, calls, "zero must block, not disable"

      Hitch.configure { |c| c.client_id_metadata_fetches_per_minute = nil }
      3.times { |i| CIMD.resolve("https://n#{i}.example/d.json", actor: "User:1") }
      assert_equal 3, calls, "nil is what disables the limit"
    end
  end



  test "the in-flight counter is released when a fetch raises" do
    Hitch.configure { |c| c.client_id_metadata_max_concurrent_fetches = 2 }
    stub_class_method(CIMD, :fetch_and_validate, ->(_id, *) { raise "boom" }) do
      assert_raises(RuntimeError) { CIMD.resolve(DOC_URL) }
    end
    assert_equal 0, CIMD.fetches_in_flight
  end

  # Asserts the contract: 100 simultaneous callers against a limit of 20
  # get exactly 20. Worth having — it would catch an implementation with
  # no locking at all.
  #
  # It does NOT reproduce the multiplication this fix was written for, and
  # I could not make it. Review measured 4x the limit against the
  # cache-backed read-check-write; in this suite neither that
  # implementation nor a split-lock variant collides, because MRI's GVL
  # offers no yield point between the read and the write and MemoryStore
  # adds none. So the fix rests on construction — one critical section, so
  # atomic by definition rather than by measurement — plus that external
  # measurement. Not on this test.
  test "the rate limit holds under simultaneous callers" do
    Hitch.configure { |c| c.client_id_metadata_fetches_per_minute = 20 }
    gate = Queue.new
    granted = Queue.new
    contenders = 100

    threads = contenders.times.map do
      Thread.new do
        gate.pop
        granted << true if CIMD.send(:charge_rate_limit, "User:1")
      end
    end
    contenders.times { gate << :go }
    threads.each(&:join)

    assert_equal 20, granted.size, "#{contenders} simultaneous callers against a limit of 20 must yield exactly 20"
  end

  # Shape rejection costs nothing outbound, so it must cost nothing from
  # the budget either — otherwise a caller spends their own minute on
  # requests that never sent a packet and is then refused a real one.
  test "a shape rejection does not spend the principal's fetch budget" do
    Hitch.configure { |c| c.client_id_metadata_fetches_per_minute = 2 }
    calls = 0

    stub_class_method(CIMD, :fetch_and_validate, ->(_id, *) { calls += 1; nil }) do
      # Non-443 port, userinfo, fragment: all refused before either cap.
      assert_nil CIMD.resolve("https://client.example:8443/a.json", actor: "User:1")
      assert_nil CIMD.resolve("https://user:pw@client.example/b.json", actor: "User:1")
      assert_nil CIMD.resolve("https://client.example/c.json#frag", actor: "User:1")
      assert_equal 0, calls, "none of those should have attempted a fetch"
      assert_equal 0, CIMD.send(:fetches_charged_to, "User:1"),
        "nor should any of them have spent the budget"

      # The budget is therefore intact for real work.
      2.times { |i| CIMD.resolve("https://client.example/real#{i}.json", actor: "User:1") }
    end
    assert_equal 2, calls, "the legitimate fetches must not have been crowded out by rejected shapes"
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
    body = { client_id: DOC_URL, client_name: "Example", redirect_uris: [ "https://client.example/cb" ] }.to_json
    handler = lambda do |socket|
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    end

    serve(handler) do |port|
      fetched = read_over_socket(port)
      assert_not_nil fetched,
        "the document must come back — if this is nil the feature is inert no matter how correct the surrounding logic is"
      assert_equal body, fetched.first
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

  # "SHOULD cache metadata respecting HTTP cache headers" — MCP
  # 2026-07-28, Client Registration. The configured TTL is a ceiling, not
  # the value: a document may ask to be cached for less (so a client's
  # redirect_uri rotation takes effect promptly) but never for more (so
  # an attacker-supplied document can't pin itself in a shared cache).
  def ttl_for(headers)
    handler = ->(socket) { socket.write("HTTP/1.1 200 OK\r\n#{headers}Content-Length: 2\r\nConnection: close\r\n\r\n{}") }
    serve(handler) { |port| read_over_socket(port)&.last }
  end

  test "a document's cache headers set its TTL, clamped by config" do
    Hitch.configure { |c| c.client_id_metadata_cache_ttl = 3600 }

    assert_equal 3600, ttl_for(""), "no cache headers falls back to the configured default"
    assert_equal 60, ttl_for("Cache-Control: max-age=60\r\n"), "a shorter max-age is honoured"
    assert_equal 3600, ttl_for("Cache-Control: max-age=999999\r\n"), "a longer max-age is clamped to the ceiling"
    assert_equal 0, ttl_for("Cache-Control: no-store\r\n")
    assert_equal 0, ttl_for("Cache-Control: no-cache\r\n")
    assert_equal 0, ttl_for("Cache-Control: private, no-store, max-age=600\r\n"), "no-store wins over max-age"
  end

  test "an Expires header sets the TTL when max-age is absent" do
    Hitch.configure { |c| c.client_id_metadata_cache_ttl = 3600 }
    now = Time.now.utc
    ttl = ttl_for("Date: #{now.httpdate}\r\nExpires: #{(now + 120).httpdate}\r\n")
    assert_in_delta 120, ttl, 2
  end

  test "a malformed Expires header falls back to the configured default" do
    Hitch.configure { |c| c.client_id_metadata_cache_ttl = 3600 }
    assert_equal 3600, ttl_for("Expires: not-a-date\r\n")
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

    stub_class_method(CIMD, :fetch_and_validate, ->(_id, *) { calls += 1; [ document, 3600 ] }) do
      3.times { assert_equal [ "https://a.test/cb" ], CIMD.resolve(DOC_URL).redirect_uris }
    end
    assert_equal 1, calls, "a cached document must not trigger a second outbound fetch"
  end

  # Without negative caching, an attacker supplies a client_id pointing at
  # a slow or hostile host and gets one outbound request per inbound
  # authorize request — the authorization server becomes the amplifier.
  test "a failed resolution is cached too" do
    calls = 0
    stub_class_method(CIMD, :fetch_and_validate, ->(_id, *) { calls += 1; nil }) do
      3.times { assert_nil CIMD.resolve(DOC_URL) }
    end
    assert_equal 1, calls, "a failing document must not trigger an outbound fetch per authorize request"
  end

  test "resolve returns nil without fetching when the feature is disabled" do
    Hitch.configure { |c| c.client_id_metadata_enabled = false }
    stub_class_method(CIMD, :fetch_and_validate, ->(_id, *) { flunk "must not fetch while disabled" }) do
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
    stub_class_method(CIMD, :fetch_and_validate, ->(_id, *) { calls += 1; CIMD::HOST_FAILURE }) do
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
    stub_class_method(CIMD, :fetch_and_validate, ->(id, *) { id.end_with?("a.json") ? nil : [ good, 3600 ] }) do
      assert_nil CIMD.resolve("https://shared.example/a.json")
      assert_not_nil CIMD.resolve("https://shared.example/b.json"),
        "a co-tenant document must still resolve after a sibling failed"
    end
  end

  test "a host that does not answer at all does block its other documents" do
    calls = 0
    stub_class_method(CIMD, :fetch_and_validate, ->(_id, *) { calls += 1; CIMD::HOST_FAILURE }) do
      assert_nil CIMD.resolve("https://dead.example/a.json")
      assert_nil CIMD.resolve("https://dead.example/b.json")
    end
    assert_equal 1, calls, "nothing answered at that host — its other documents are not worth a second connection"
  end

  test "a trailing dot is the same host for negative-caching purposes" do
    calls = 0
    stub_class_method(CIMD, :fetch_and_validate, ->(_id, *) { calls += 1; CIMD::HOST_FAILURE }) do
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
    stub_class_method(CIMD, :fetch_and_validate, ->(id, *) { hosts << URI.parse(id).host; nil }) do
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
