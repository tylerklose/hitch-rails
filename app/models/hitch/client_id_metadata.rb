# frozen_string_literal: true

require "net/http"
require "resolv"
require "ipaddr"
require "json"
require "timeout"
require "digest"

module Hitch
  # Client ID Metadata Documents (CIMD).
  #
  # MCP 2026-07-28 deprecates Dynamic Client Registration in favour of
  # CIMD: instead of pre-registering and receiving an opaque client_id,
  # a client uses an https URL as its client_id, and the authorization
  # server fetches the client metadata from that URL.
  #
  # That inverts the trust model. DCR data arrives on a request the
  # server is already handling; CIMD makes the AUTHORIZATION SERVER issue
  # an outbound request to a URL the caller chose. /oauth/authorize
  # requires a signed-in principal, so the caller is authenticated rather
  # than anonymous — a low bar on any host with open sign-up, and note
  # the GET consent path carries no CSRF token, so a fetch can be driven
  # from a logged-in victim's browser. Every guard here exists because of
  # that inversion:
  #
  #   - https only, no redirects followed, no userinfo, no fragment
  #   - DNS resolved once, every address checked against a blocklist of
  #     non-public ranges, then the connection PINNED to the checked
  #     address via Net::HTTP#ipaddr= so a second lookup can't return a
  #     different answer (DNS rebinding)
  #   - hard caps on time and response size
  #   - the document's own `client_id` must equal the URL it came from,
  #     so a document cannot claim to be a different client
  #   - successes and failures are both cached, so a hostile or dead URL
  #     cannot be used to make the authorize endpoint issue an outbound
  #     request per inbound request. Note this one depends on the host
  #     having a real Rails.cache: under a NullStore (Rails' default in
  #     test, and in development without tmp/caching-dev.txt) nothing is
  #     retained between requests and the amplification guard is absent.
  #
  # Disabled unless the host opts in (`config.client_id_metadata_enabled`).
  # The feature adds an outbound-fetch surface to an endpoint that had
  # none, and DCR still works, so it is not something to switch on for an
  # adopter who has not considered it.
  class ClientIdMetadata
    # Non-public destinations. A CIMD URL resolving into any of these is
    # someone using the authorization server as a proxy into a network
    # they cannot otherwise reach — cloud metadata endpoints
    # (169.254.169.254), internal services, the host itself.
    BLOCKED_IPV4 = [
      "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
      "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24",
      "192.88.99.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24",
      "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4", "255.255.255.255/32"
    ].map { |r| IPAddr.new(r) }.freeze

    # IPv6 is an ALLOWLIST, not a denylist. A denylist cannot be made
    # complete here: RFC 8215 reserves 64:ff9b:1::/48 for network-specific
    # NAT64 prefixes, and 6to4 and Teredo embed an arbitrary IPv4
    # destination that a denylist would have to decode to evaluate. So
    # only global unicast is allowed through, minus the special-purpose
    # blocks carved out of it. Everything else — loopback, link-local,
    # unique-local, IPv4-mapped, IPv4-compatible, site-local, NAT64,
    # multicast — falls outside 2000::/3 and is refused by default.
    GLOBAL_UNICAST_IPV6 = IPAddr.new("2000::/3")

    EXCLUDED_IPV6 = [
      "2001::/32",     # Teredo — tunnels to an arbitrary IPv4 endpoint
      "2001:10::/28",  # ORCHID (deprecated)
      "2001:20::/28",  # ORCHIDv2
      "2001:2::/48",   # benchmarking — the v6 counterpart of 198.18.0.0/15
      "2001:db8::/32", # documentation
      "2002::/16",     # 6to4 — embeds an arbitrary IPv4 destination
      "3fff::/20"      # documentation (RFC 9637)
    ].map { |r| IPAddr.new(r) }.freeze

    # CIMD documents live on ordinary https endpoints. Allowing an
    # arbitrary port would let a caller drive TLS connections to any
    # host:port from the authorization server's egress address — the
    # standard way around a third party's source-IP allowlist.
    ALLOWED_PORT = 443

    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 3

    # A ceiling on the WHOLE resolution: DNS plus connect plus read.
    # read_timeout only bounds the gap between reads, so a server
    # trickling bytes forever never trips it, and Ruby's resolver has its
    # own multi-second retry ladder outside both socket timeouts.
    TOTAL_BUDGET = 5

    MAX_BYTES = 64 * 1024
    MAX_REDIRECT_URIS = 20

    # Cached negatives are deliberately short-lived relative to positives:
    # long enough that a hostile URL cannot drive one fetch per request,
    # short enough that a client fixing a genuinely broken document isn't
    # locked out for an hour.
    FAILURE_CACHE_TTL = 60

    Document = Struct.new(:client_id, :client_name, :redirect_uris, keyword_init: true)

    # Guards the in-flight counter below. Process-wide: the cap bounds
    # this process's share of outbound work, so a fleet ceiling is the
    # configured value times the worker count.
    @fetch_mutex = Mutex.new
    @fetches_in_flight = 0

    # Failure sentinels. Only HOST_FAILURE — nothing at that host
    # answered — may block the host's other documents; a document-level
    # failure (plain nil) must not, or one bogus URL would take an entire
    # CIMD-hosting domain down for everyone on it.
    HOST_FAILURE = :host_failure
    # Rejected on the URL's shape alone, before any network work.
    SHAPE_REJECT = :shape_reject
    # Refused because a cap was already spent — no fetch was attempted.
    # Distinct from the two above because it says NOTHING about the URL
    # or the host, and so must never be cached: writing a host failure
    # here would turn cap exhaustion into a way to poison a legitimate
    # host's entry for everyone.
    CAPACITY_EXCEEDED = :capacity_exceeded
    # Refused because this principal spent its minute budget. Same rule:
    # no fetch happened, so nothing is known and nothing is cached.
    RATE_LIMITED = :rate_limited

    class << self
      # A client_id is a CIMD reference when it is an https URL. Opaque
      # DCR client_ids (UUIDs) never match, so the two schemes coexist
      # without ambiguity.
      def reference?(client_id)
        return false if client_id.blank?
        return false unless Hitch.configuration.client_id_metadata_enabled

        uri = URI.parse(client_id.to_s)
        # "The client_id URL MUST use the 'https' scheme and contain a
        # path component" — MCP 2026-07-28, Client Registration. A bare
        # origin is not a metadata document URL, so it falls through to
        # the opaque/DCR lookup rather than triggering an outbound fetch.
        uri.is_a?(URI::HTTPS) && uri.host.present? && uri.path.present? && uri.path != "/"
      rescue URI::InvalidURIError
        false
      end

      # Returns a Document, or nil for anything that isn't a usable
      # client metadata document. Never raises into the authorize flow:
      # a fetch failure is an untrusted client's problem, not a 500.
      # `actor` identifies the signed-in principal driving this
      # resolution, for per-actor rate limiting. Optional: omitted, only
      # the concurrency cap applies.
      def resolve(client_id, actor: nil)
        return nil unless reference?(client_id)

        key = cache_key(client_id)
        cached = cache_read(key)

        unless cached.nil?
          return nil if cached == false

          document = rehydrate(cached)
          return document if document

          # An entry we can't read is treated as a miss rather than
          # propagating. A Document member added in a later release, a
          # rolling deploy sharing a cache between two versions, or a
          # host configuring a coder that stringifies keys would
          # otherwise turn /oauth/authorize into a 500 for that
          # client_id until the TTL expired.
          cache_delete(key)
        end

        host = uri_host(client_id)
        return nil if host.nil?
        # A host that just failed to answer at all is not retried,
        # whatever path or query is hung off it. Keyed by URL alone the
        # negative cache is defeated by appending ?n=1, ?n=2 — each a
        # distinct key and each a valid CIMD reference.
        return nil if cache_read(failure_key(host)) == false

        # Both caps are consulted only on a genuine miss. A cached
        # resolution costs nothing outbound, so charging it against
        # either budget would penalise the common case and make a busy,
        # correctly-configured server throttle itself.
        #
        # Capacity is taken FIRST, and the minute budget is only charged
        # once a slot is held. The other order spends a token on a
        # request that never sent a packet — which turns a squeeze on the
        # slots into a way to drain every victim's own budget while they
        # retry, locking them out past the point where the slots free up.
        outcome = with_fetch_capacity do
          charge_rate_limit(actor) ? fetch_and_validate(client_id) : RATE_LIMITED
        end

        case outcome
        when CAPACITY_EXCEEDED, RATE_LIMITED
          # Deliberately no cache write of any kind — see the constants.
          nil
        when Array
          # [document, ttl] — the TTL is derived from the document's own
          # HTTP cache headers, clamped by config.
          document, ttl = outcome
          cache_write(key, document.to_h, ttl) if ttl.positive?
          document
        when SHAPE_REJECT
          # Rejected on the URL alone, before any network work happened.
          # Caching that costs more than it saves: repeating the check is
          # free, while writing an entry per malformed client_id lets a
          # caller fill a shared cache — evicting the host app's own
          # entries — without sending a single packet.
          nil
        when HOST_FAILURE
          cache_write(key, false, FAILURE_CACHE_TTL)
          cache_write(failure_key(host), false, FAILURE_CACHE_TTL)
          nil
        else
          # A document-level failure — 404, malformed JSON, a document
          # naming the wrong client_id. It says nothing about its
          # neighbours, so it must NOT block them: one domain hosting
          # many client documents is the normal CIMD deployment shape,
          # and poisoning the host on a per-document failure would let
          # anyone hold that whole domain offline by requesting a single
          # bogus URL on it once a minute.
          cache_write(key, false, FAILURE_CACHE_TTL)
          nil
        end
      end

      # Number of fetches in flight right now. Test seam.
      def fetches_in_flight
        @fetch_mutex.synchronize { @fetches_in_flight.to_i }
      end

      private

      # A plain counter under a mutex rather than a Semaphore, so the
      # limit is read from config at acquisition time — a host may change
      # it, and tests do.
      def with_fetch_capacity
        # nil disables, matching the rate-limit knob. Integers are honored
        # literally — including 0, which blocks every fetch. Treating 0 as
        # "disabled" would make the most restrictive-looking setting the
        # least restrictive one.
        limit = integer_setting(:client_id_metadata_max_concurrent_fetches)
        return yield if limit.nil?

        # The increment and the ensure that undoes it must not be
        # separable by an asynchronous exception. Rack::Timeout, an outer
        # Timeout.timeout, or Puma's force_shutdown_after all deliver via
        # Thread#raise, and one landing between the two would leak the
        # slot permanently — after `limit` of those, CIMD is dead for the
        # life of the process, silently and with nothing to alert on.
        Thread.handle_interrupt(Object => :never) do
          acquired = @fetch_mutex.synchronize do
            next false if @fetches_in_flight >= limit

            @fetches_in_flight += 1
            true
          end

          # Fails closed, and refuses rather than queues: queueing is what
          # consumes the request thread this cap exists to protect.
          next CAPACITY_EXCEEDED unless acquired

          begin
            Thread.handle_interrupt(Object => :immediate) { yield }
          ensure
            @fetch_mutex.synchronize { @fetches_in_flight -= 1 }
          end
        end
      end

      # Fixed 60-second window. Coarse on purpose: a sliding window costs
      # a read-modify-write per request for precision that does not
      # change what this bounds — the order of magnitude of traffic one
      # principal can aim at a third party.
      def charge_rate_limit(actor)
        limit = integer_setting(:client_id_metadata_fetches_per_minute)
        # nil disables. 0 and below block, matching the concurrency knob —
        # the most restrictive-looking setting must not be the one that
        # removes the protection.
        return true if limit.nil?
        return false if limit <= 0

        if actor.blank?
          # Not reachable from the shipped controller — both authorize
          # actions bail to require_principal! first — but a host whose
          # principal_method returns something without #id (a claims
          # hash, a bare identifier) would land here and silently get no
          # rate limiting at all.
          warn_once(:cimd_rate_limit_no_actor,
                    "client_id_metadata_fetches_per_minute is set but the resolution had no actor; " \
                    "per-principal rate limiting is not being applied")
          return true
        end

        key = "hitch/cimd/v1/rate/#{Digest::SHA256.hexdigest(actor.to_s)}/#{(Time.now.to_i / 60)}"
        spent = cache_read(key)
        if spent.nil? && cache_unavailable?
          # Fail open — a cache blip must not break /oauth/authorize —
          # but say so. This limiter is the argument for CIMD being safe
          # to enable, and it evaporates exactly when infrastructure is
          # degraded. Silence there is the worst property it could have.
          warn_once(:cimd_rate_limit_cache_down,
                    "Rails.cache is unavailable; CIMD per-principal rate limiting is not being applied")
          return true
        end

        spent = spent.to_i
        return false if spent >= limit

        # Not atomic. A racing pair of requests can both read the same
        # value and each write spent+1, so a determined caller overshoots
        # the limit by roughly the concurrency cap — which the cap above
        # already bounds. An atomic increment would need a store-specific
        # API, and this is a volume bound, not an accounting ledger.
        #
        # A store whose reads succeed but whose writes fail is the nastier
        # outage: the counter never advances, so every request looks like
        # the first and the limit is gone entirely. Reads alone cannot
        # detect that, so the write result is checked.
        unless cache_write(key, spent + 1, 120)
          warn_once(:cimd_rate_limit_write_failed,
                    "Rails.cache writes are failing; CIMD per-principal rate limiting is not being applied")
        end
        true
      end

      # Validates the rebuilt struct rather than relying on Document.new
      # to object. A keyword_init Struct accepts string keys without
      # raising and yields a half-built Document with nil members — so
      # the stringifying-coder case this guard exists for would sail
      # straight through an ArgumentError rescue.
      def rehydrate(cached)
        document = Document.new(**cached)
        return nil unless document.client_id.is_a?(String) && document.redirect_uris.is_a?(Array)

        document
      rescue ArgumentError, TypeError
        nil
      end

      # Versioned so a change to Document's shape invalidates old entries
      # instead of colliding with them.
      def cache_key(client_id)
        "hitch/cimd/v1/#{Digest::SHA256.hexdigest(client_id.to_s)}"
      end

      def failure_key(host)
        "hitch/cimd/v1/failed-host/#{Digest::SHA256.hexdigest(normalized_host(host))}"
      end

      # "evil.example" and "evil.example." are the same DNS name and the
      # same destination; without stripping the root label they would be
      # two cache keys, which is one more outbound fetch than intended.
      def normalized_host(host)
        host.to_s.downcase.chomp(".")
      end

      def uri_host(client_id)
        URI.parse(client_id.to_s).host.presence
      rescue URI::InvalidURIError
        nil
      end

      # Reads a numeric setting without trusting its type. The docs say
      # "nil disables", and the obvious wrong guess at that is `false` —
      # whose #to_i does not exist, which would raise NoMethodError
      # straight out of resolve and 500 /oauth/authorize on the
      # default-on path. Anything not coercible to an Integer is treated
      # as unset rather than fatal.
      def integer_setting(name)
        case (value = Hitch.configuration.public_send(name))
        when Integer then value
        # Strings are accepted because settings often arrive from ENV.
        # Floats are NOT: Kernel.Integer(2.5) truncates to 2, which would
        # silently honour a value the docs say is unset.
        when String then Integer(value, exception: false)
        end
      end

      # Distinguishes "cache is down" from "key genuinely absent", so the
      # rate limiter can say which one it is failing open on.
      def cache_unavailable?
        @cache_unavailable
      end

      # A cache outage must not take the authorize endpoint with it.
      def cache_read(key)
        value = Rails.cache.read(key)
        @cache_unavailable = false
        value
      rescue StandardError
        @cache_unavailable = true
        nil
      end

      # Warns once per process per reason. These describe a standing
      # misconfiguration, not a per-request event; logging them on every
      # authorize would bury the thing it is warning about.
      def warn_once(reason, message)
        @warned ||= {}
        return if @warned[reason]

        @warned[reason] = true
        Rails.logger&.warn("[hitch] #{message}")
      rescue StandardError
        nil
      end

      # Returns whether the value was actually stored. Callers that only
      # want best-effort persistence can ignore it; the rate limiter
      # cannot, because a silently-dropped write disables it.
      def cache_write(key, value, ttl)
        Rails.cache.write(key, value, expires_in: ttl) ? true : false
      rescue StandardError
        false
      end

      def cache_delete(key)
        Rails.cache.delete(key)
      rescue StandardError
        nil
      end

      # Returns a Document, or one of the failure sentinels. The
      # distinction exists so resolve can tell a failure that is the
      # HOST's (nothing there answers) from one that is this DOCUMENT's
      # (the host answered, the document was unusable) — only the former
      # may block that host's other documents.
      def fetch_and_validate(client_id)
        uri = URI.parse(client_id)
        return SHAPE_REJECT if uri.userinfo.present? || uri.fragment.present?
        return SHAPE_REJECT unless uri.port == ALLOWED_PORT

        Timeout.timeout(TOTAL_BUDGET) do
          address = safe_address(uri.host)
          return HOST_FAILURE if address.nil?

          fetched = fetch(uri, address)
          return HOST_FAILURE if fetched == HOST_FAILURE
          return nil if fetched.nil?

          body, ttl = fetched
          document = build_document(client_id, body)
          document && [ document, ttl ]
        end
      rescue Timeout::Error => e
        log_rejection(client_id, "#{e.class}: #{e.message}")
        HOST_FAILURE
      rescue URI::InvalidURIError => e
        log_rejection(client_id, "#{e.class}: #{e.message}")
        SHAPE_REJECT
      rescue JSON::ParserError => e
        log_rejection(client_id, "#{e.class}: #{e.message}")
        nil
      end

      # Resolve once and return a single vetted address. Every address the
      # name resolves to must be public — a name returning one public and
      # one private address is rejected outright rather than cherry-picked,
      # since that pattern is itself the rebinding signature.
      def safe_address(host)
        literal = ip_literal(host)
        return blocked?(literal) ? nil : literal.to_s if literal

        addresses = Resolv.getaddresses(host).filter_map { |a| ip_literal(a) }
        return nil if addresses.empty?
        return nil if addresses.any? { |a| blocked?(a) }

        addresses.first.to_s
      rescue Resolv::ResolvError, StandardError
        nil
      end

      def ip_literal(value)
        IPAddr.new(value.to_s)
      rescue IPAddr::Error
        nil
      end

      def blocked?(addr)
        return BLOCKED_IPV4.any? { |range| range.include?(addr) } if addr.ipv4?
        return true unless GLOBAL_UNICAST_IPV6.include?(addr)

        EXCLUDED_IPV6.any? { |range| range.include?(addr) }
      end

      def fetch(uri, address)
        build_connection(uri, address).start { |http| read_document(http, uri) }
      rescue StandardError => e
        # Connect refused, TLS failure, socket reset: the host did not
        # answer, which says nothing about any individual document on it.
        log_rejection(uri.to_s, "#{e.class}: #{e.message}")
        HOST_FAILURE
      end

      def build_connection(uri, address)
        # p_addr explicitly nil. Net::HTTP.new defaults it to :ENV, which
        # silently routes through http_proxy — reaching the destination
        # from the proxy's egress address rather than this app's, which is
        # exactly the property ALLOWED_PORT exists to control. If a host
        # wants proxying it should be a decision, not a leftover env var.
        http = Net::HTTP.new(uri.host, uri.port, nil)
        # Pin the socket to the address already vetted, while leaving the
        # hostname in place for SNI and certificate verification. Without
        # this, Net::HTTP resolves the name a second time and the answer
        # that was checked is not necessarily the answer that is used.
        http.ipaddr = address
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        # A read timeout on a GET is otherwise retried by reconnecting and
        # replaying the whole request, doubling every budget above.
        http.max_retries = 0
        http
      end

      # The block form of #request is load-bearing, not stylistic.
      # Without a block, Net::HTTPResponse#reading_body calls `self.body`
      # and buffers the ENTIRE response before #request returns — so a cap
      # applied afterwards caps nothing, and a later #read_body raises
      # "called twice". Passing the block keeps the body unread until
      # read_capped streams it.
      def read_document(http, uri)
        http.request(Net::HTTP::Get.new(uri, "Accept" => "application/json")) do |response|
          # Redirects are not followed at all. A followed redirect would
          # need the whole address-vetting dance again for each hop, and a
          # client metadata document has no legitimate reason to move
          # during a resolution.
          return nil unless response.is_a?(Net::HTTPOK)
          # An advisory check only — Content-Length is written by the same
          # party as the body, and can simply be omitted under chunked
          # framing. read_capped is what actually enforces the limit.
          return nil if response["Content-Length"].to_i > MAX_BYTES

          body = read_capped(response)
          return nil if body.nil?

          return [ body, cache_ttl_for(response) ]
        end
      end

      # "SHOULD cache metadata respecting HTTP cache headers" — MCP
      # 2026-07-28, Client Registration.
      #
      # The configured TTL becomes a CEILING rather than the value: a
      # document is allowed to ask to be cached for less time than the
      # host's default, which is how a client rotates its redirect_uris
      # promptly, but not for longer, which is how an attacker-supplied
      # document would otherwise pin itself in a shared cache. Returns 0
      # when the document asks not to be stored at all.
      def cache_ttl_for(response)
        ceiling = Hitch.configuration.client_id_metadata_cache_ttl.to_i
        directives = response["Cache-Control"].to_s.downcase

        return 0 if directives.include?("no-store") || directives.include?("no-cache")

        seconds = directives[/max-age\s*=\s*(\d+)/, 1]&.to_i
        seconds ||= expires_in_seconds(response["Expires"], response["Date"])
        return ceiling if seconds.nil?

        seconds.clamp(0, ceiling)
      end

      def expires_in_seconds(expires, date)
        return nil if expires.blank?

        now = date.present? ? Time.httpdate(date) : Time.now
        (Time.httpdate(expires) - now).to_i
      rescue ArgumentError
        nil
      end

      # Content-Length is a claim, not a guarantee — read defensively and
      # abandon anything that keeps going past the cap.
      def read_capped(response)
        body = +""
        response.read_body do |chunk|
          body << chunk
          return nil if body.bytesize > MAX_BYTES
        end
        body
      end

      def build_document(client_id, body)
        parsed = JSON.parse(body)
        return log_rejection(client_id, "document is not a JSON object") unless parsed.is_a?(Hash)

        # The binding that makes CIMD safe: the document must name itself
        # with the exact URL it was fetched from. Without this check, one
        # hosted document could impersonate any other client by listing
        # someone else's redirect_uris.
        unless parsed["client_id"].is_a?(String) && parsed["client_id"] == client_id
          return log_rejection(client_id, "document client_id does not match the URL it was fetched from")
        end

        # Strictly an Array — `Array(value)` would wrap a bare String into
        # a one-element list, quietly accepting a malformed document from
        # an untrusted source. Nothing here should be coerced into shape.
        declared = parsed["redirect_uris"]
        return log_rejection(client_id, "redirect_uris is not an array") unless declared.is_a?(Array)

        redirect_uris = declared.select { |u| u.is_a?(String) }
        return log_rejection(client_id, "document declares no redirect_uris") if redirect_uris.empty?
        return log_rejection(client_id, "document declares too many redirect_uris") if redirect_uris.size > MAX_REDIRECT_URIS

        # "The metadata document MUST include at least the following
        # properties: client_id, client_name, redirect_uris" — MCP
        # 2026-07-28, Client Registration. Absent or non-string
        # client_name makes the document invalid rather than merely
        # nameless.
        client_name = parsed["client_name"]
        unless client_name.is_a?(String) && client_name.present?
          return log_rejection(client_id, "document is missing the required client_name")
        end

        Document.new(
          client_id: client_id,
          # Attacker-controllable, exactly like the DCR client_name.
          # Retained for audit; never trusted for consent-screen display.
          client_name: client_name,
          redirect_uris: redirect_uris
        )
      end

      # This class's contract is that it never raises into the authorize
      # flow, and that has to hold for the logging too.
      def log_rejection(client_id, reason)
        Rails.logger.info("[hitch] rejected client id metadata document #{client_id.inspect}: #{reason}")
        nil
      rescue StandardError
        nil
      end
    end
  end
end
