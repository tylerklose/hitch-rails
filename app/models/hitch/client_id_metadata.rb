# frozen_string_literal: true

require "net/http"
require "resolv"
require "ipaddr"
require "json"

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
  # an outbound request to a URL an unauthenticated caller chose. Every
  # guard in this class exists because of that inversion:
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
  #     request per inbound request
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

    BLOCKED_IPV6 = [
      "::/128", "::1/128", "::ffff:0:0/96", "64:ff9b::/96", "100::/64",
      "2001:db8::/32", "fc00::/7", "fe80::/10", "ff00::/8"
    ].map { |r| IPAddr.new(r) }.freeze

    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 3
    MAX_BYTES = 64 * 1024
    MAX_REDIRECT_URIS = 20

    # Cached negatives are deliberately short-lived relative to positives:
    # long enough that a hostile URL cannot drive one fetch per request,
    # short enough that a client fixing a genuinely broken document isn't
    # locked out for an hour.
    FAILURE_CACHE_TTL = 60

    Document = Struct.new(:client_id, :client_name, :redirect_uris, keyword_init: true)

    class << self
      # A client_id is a CIMD reference when it is an https URL. Opaque
      # DCR client_ids (UUIDs) never match, so the two schemes coexist
      # without ambiguity.
      def reference?(client_id)
        return false if client_id.blank?
        return false unless Hitch.configuration.client_id_metadata_enabled

        uri = URI.parse(client_id.to_s)
        uri.is_a?(URI::HTTPS) && uri.host.present?
      rescue URI::InvalidURIError
        false
      end

      # Returns a Document, or nil for anything that isn't a usable
      # client metadata document. Never raises into the authorize flow:
      # a fetch failure is an untrusted client's problem, not a 500.
      def resolve(client_id)
        return nil unless reference?(client_id)

        cached = Rails.cache.read(cache_key(client_id))
        return cached.presence && rehydrate(cached) unless cached.nil?

        document = fetch_and_validate(client_id)
        Rails.cache.write(
          cache_key(client_id),
          document ? document.to_h : false,
          expires_in: document ? Hitch.configuration.client_id_metadata_cache_ttl : FAILURE_CACHE_TTL
        )
        document
      end

      private

      def rehydrate(cached) = Document.new(**cached)

      def cache_key(client_id)
        "hitch/cimd/#{Digest::SHA256.hexdigest(client_id.to_s)}"
      end

      def fetch_and_validate(client_id)
        uri = URI.parse(client_id)
        return nil if uri.userinfo.present? || uri.fragment.present?

        address = safe_address(uri.host)
        return nil if address.nil?

        body = fetch(uri, address)
        return nil if body.nil?

        build_document(client_id, body)
      rescue URI::InvalidURIError, JSON::ParserError => e
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
        ranges = addr.ipv4? ? BLOCKED_IPV4 : BLOCKED_IPV6
        ranges.any? { |range| range.include?(addr) }
      end

      def fetch(uri, address)
        http = Net::HTTP.new(uri.host, uri.port)
        # Pin the socket to the address already vetted, while leaving the
        # hostname in place for SNI and certificate verification. Without
        # this, Net::HTTP resolves the name a second time and the answer
        # that was checked is not necessarily the answer that is used.
        http.ipaddr = address
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT

        http.start do |connection|
          response = connection.request(Net::HTTP::Get.new(uri, "Accept" => "application/json"))
          # Redirects are not followed at all. A followed redirect would
          # need the whole address-vetting dance again for each hop, and a
          # client metadata document has no legitimate reason to move
          # during a resolution.
          return nil unless response.is_a?(Net::HTTPOK)
          return nil if response["Content-Length"].to_i > MAX_BYTES

          read_capped(response)
        end
      rescue StandardError => e
        log_rejection(uri.to_s, "#{e.class}: #{e.message}")
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

        Document.new(
          client_id: client_id,
          # Attacker-controllable, exactly like the DCR client_name.
          # Retained for audit; never trusted for consent-screen display.
          client_name: parsed["client_name"].is_a?(String) ? parsed["client_name"] : nil,
          redirect_uris: redirect_uris
        )
      end

      def log_rejection(client_id, reason)
        Rails.logger.info("[hitch] rejected client id metadata document #{client_id.inspect}: #{reason}")
        nil
      end
    end
  end
end
