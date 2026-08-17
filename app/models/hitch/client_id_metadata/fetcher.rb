# frozen_string_literal: true

require "net/http"
require "resolv"
require "ipaddr"
require "json"
require "timeout"

module Hitch
  class ClientIdMetadata
    # The SSRF-hardened document fetch: resolve once, vet every address,
    # pin the connection to the vetted address, cap time and size, follow
    # nothing, and accept only a document that names itself with the exact
    # URL it came from.
    class Fetcher
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

      OPEN_TIMEOUT = 2
      READ_TIMEOUT = 3

      # A ceiling on the WHOLE resolution: DNS plus connect plus read.
      # read_timeout only bounds the gap between reads, so a server
      # trickling bytes forever never trips it, and Ruby's resolver has its
      # own multi-second retry ladder outside both socket timeouts.
      TOTAL_BUDGET = 5

      MAX_BYTES = 64 * 1024
      MAX_REDIRECT_URIS = 20

      # Nothing at that host answered — may block the host's other
      # documents. Distinct from a document-level failure (plain nil),
      # which must not, or one bogus URL would take an entire CIMD-hosting
      # domain down for everyone on it.
      HOST_FAILURE = :host_failure

      class << self
        # [document, ttl] on success (TTL derived from the document's own
        # cache headers, clamped by config), nil for an unusable document,
        # HOST_FAILURE when nothing at the host answered.
        def call(client_id, uri)
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
        rescue JSON::ParserError => e
          log_rejection(client_id, "#{e.class}: #{e.message}")
          nil
        end

        private

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
            unless response.is_a?(Net::HTTPOK)
              return log_rejection(uri.to_s, "responded #{response.code}, not 200")
            end

            # An advisory check only — Content-Length is written by the same
            # party as the body, and can simply be omitted under chunked
            # framing. read_capped is what actually enforces the limit.
            if response["Content-Length"].to_i > MAX_BYTES
              return log_rejection(uri.to_s, "declared Content-Length above the #{MAX_BYTES}-byte cap")
            end

            body = read_capped(response)
            return log_rejection(uri.to_s, "body exceeded the #{MAX_BYTES}-byte cap while streaming") if body.nil?

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

        # CIMD's contract is that it never raises into the authorize flow,
        # and that has to hold for the logging too.
        def log_rejection(client_id, reason)
          Rails.logger.info("[hitch] rejected client id metadata document #{client_id.inspect}: #{reason}")
          nil
        rescue StandardError
          nil
        end
      end
    end
  end
end
