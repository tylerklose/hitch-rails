# frozen_string_literal: true

require "uri"

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
    Document = Struct.new(:client_id, :client_name, :redirect_uris, keyword_init: true)

    # CIMD documents live on ordinary https endpoints. Allowing an
    # arbitrary port would let a caller drive TLS connections to any
    # host:port from the authorization server's egress address — the
    # standard way around a third party's source-IP allowlist.
    ALLOWED_PORT = 443

    # Process-wide by design: both throttle bounds are this process's share
    # of outbound work (see Throttle).
    @throttle = Throttle.new

    # Failure sentinels (see Fetcher and Throttle for the semantics).
    HOST_FAILURE = Fetcher::HOST_FAILURE
    # Refused because a cap was already spent — no fetch was attempted, so
    # nothing is known and nothing may be cached (see Throttle).
    CAPACITY_EXCEEDED = Throttle::CAPACITY_EXCEEDED
    # Refused because this principal spent its minute budget. Same rule.
    RATE_LIMITED = :rate_limited

    # Result of a diagnostic fetch. Separate from Document deliberately:
    # this is operator-facing and describes an attempt, not a client.
    Diagnosis = Struct.new(:outcome, :detail, keyword_init: true) do
      def ok? = outcome == :ok
    end

    class << self
      # A client_id is a CIMD reference when it is an https URL. Opaque
      # DCR client_ids (UUIDs) never match, so the two schemes coexist
      # without ambiguity.
      def reference?(client_id)
        return false unless Hitch.configuration.client_id_metadata_enabled

        document_url?(client_id)
      end

      # The shape half of reference?, without consulting the enablement
      # flag. Split out so the operator diagnostic can run BEFORE CIMD is
      # switched on — which is the only moment its answer is useful.
      #
      # "The client_id URL MUST use the 'https' scheme and contain a path
      # component" — MCP 2026-07-28, Client Registration. A bare origin
      # is not a metadata document URL, so it falls through to the
      # opaque/DCR lookup rather than triggering an outbound fetch.
      def document_url?(client_id)
        return false if client_id.blank?

        uri = URI.parse(client_id.to_s)
        uri.is_a?(URI::HTTPS) && uri.host.present? && uri.path.present? && uri.path != "/" &&
          !trailing_dot_host?(uri) && !dot_path_segments?(uri)
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

        key = Cache.key(client_id)
        cached = Cache.read(key)

        unless cached.nil?
          return nil if cached == false

          document = Cache.rehydrate(cached)
          return document if document

          # An entry we can't read is treated as a miss rather than
          # propagating. A Document member added in a later release, a
          # rolling deploy sharing a cache between two versions, or a
          # host configuring a coder that stringifies keys would
          # otherwise turn /oauth/authorize into a 500 for that
          # client_id until the TTL expired.
          Cache.delete(key)
        end

        # Shape is judged BEFORE either cap is touched. Rejecting a URL on
        # its scheme, port, userinfo or fragment costs nothing outbound,
        # so charging it would let a caller spend their own minute budget
        # on requests that never sent a packet — and then be refused a
        # legitimate fetch. Shape rejects are never cached, either:
        # repeating the check is free, while writing an entry per
        # malformed client_id lets a caller fill a shared cache —
        # evicting the host app's own entries — without sending a single
        # packet.
        target = fetch_target(client_id)
        return nil if target.nil?

        # DNS-empty or every address blocked: the host itself is not
        # retried, whatever path or query is hung off it. Keyed by URL
        # alone that negative is defeated by appending ?n=1. TLS failure,
        # timeout after connect, RST, and HTTP errors are per-URL only —
        # draft-ietf-oauth-client-id-metadata-document-02 §5.2 says do
        # not cache errors; the per-URL negative and fetches_per_minute
        # are the amplification guard.
        host = target.host
        return nil if Cache.read(Cache.failure_key(host)) == false

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
          charge_rate_limit(actor) ? Fetcher.call(client_id, target) : RATE_LIMITED
        end

        case outcome
        when CAPACITY_EXCEEDED, RATE_LIMITED
          # Deliberately no cache write of any kind — see the constants.
          nil
        when Array
          # [document, ttl] — the TTL is derived from the document's own
          # HTTP cache headers, clamped by config.
          document, ttl = outcome
          Cache.write(key, document.to_h, ttl) if ttl.positive?
          document
        when HOST_FAILURE
          Cache.write(key, false, Cache::FAILURE_TTL)
          Cache.write(Cache.failure_key(host), false, Cache::FAILURE_TTL)
          nil
        else
          # A document-level failure — 404, malformed JSON, a document
          # naming the wrong client_id. It says nothing about its
          # neighbours, so it must NOT block them: one domain hosting
          # many client documents is the normal CIMD deployment shape,
          # and poisoning the host on a per-document failure would let
          # anyone hold that whole domain offline by requesting a single
          # bogus URL on it once a minute.
          Cache.write(key, false, Cache::FAILURE_TTL)
          nil
        end
      end

      # Number of fetches in flight right now. Test seam.
      def fetches_in_flight
        @throttle.in_flight
      end

      # Operator-facing check that this host can actually reach and parse a
      # client metadata document, for confirming egress before enabling
      # CIMD. Takes a URL the operator already trusts.
      #
      # Reports only. Whether one document is reachable right now is a
      # different question from whether this server supports CIMD, and
      # only the second belongs in the discovery document: a capability
      # that moved with network conditions would be stale for up to the
      # discovery cache lifetime, and would tell clients nothing they
      # could act on.
      #
      # Skips the caches and the per-principal limit (there is no
      # principal) but not the SSRF constraints or the concurrency cap —
      # exercising the real fetch path is the entire point.
      def diagnose(client_id)
        # Deliberately ignores client_id_metadata_enabled. The whole point
        # is to answer "can this host reach a document?" BEFORE deciding
        # to turn CIMD on, so gating the probe on the setting it informs
        # makes it useless exactly when it is needed. That flag governs
        # discovery and real authorization traffic; it does not govern an
        # operator running a command.
        unless document_url?(client_id)
          return Diagnosis.new(outcome: :not_a_reference,
                               detail: "not an https URL with a path component, so it would be treated as an opaque client_id")
        end

        target = fetch_target(client_id)
        if target.nil?
          return Diagnosis.new(outcome: :rejected_shape,
                               detail: "must be https on port #{ALLOWED_PORT}, with no userinfo and no fragment")
        end

        case (outcome = with_fetch_capacity { Fetcher.call(client_id, target) })
        when Array
          Diagnosis.new(outcome: :ok, detail: "resolved #{outcome.first.redirect_uris.length} redirect_uri(s)")
        when CAPACITY_EXCEEDED
          Diagnosis.new(outcome: :no_capacity, detail: "every fetch slot is currently busy")
        when HOST_FAILURE
          Diagnosis.new(outcome: :unreachable,
                        detail: "DNS returned no usable public address — check direct egress on port #{ALLOWED_PORT}; " \
                                "an ambient http_proxy is deliberately ignored")
        else
          Diagnosis.new(outcome: :invalid_document,
                        detail: "the host answered but the document was unusable — the log line for this URL says why")
        end
      end

      private

      # The limit is read from config at acquisition time — a host may
      # change it, and tests do.
      def with_fetch_capacity(&block)
        @throttle.with_capacity(integer_setting(:client_id_metadata_max_concurrent_fetches), &block)
      end

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

        @throttle.charge(actor, limit: limit)
      end

      # Test seam: current count for an actor in this minute.
      def fetches_charged_to(actor)
        @throttle.charged_to(actor)
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

      # Parses a client_id into the URI to fetch, or nil when its shape
      # rules it out. Deliberately separate from the Fetcher call and
      # called before the caps: none of these checks costs a packet, so
      # none of them should cost a token.
      def fetch_target(client_id)
        uri = URI.parse(client_id)
        return nil if uri.userinfo.present? || uri.fragment.present?
        return nil unless uri.port == ALLOWED_PORT
        return nil if trailing_dot_host?(uri) || dot_path_segments?(uri)

        uri
      rescue URI::InvalidURIError
        # Unreachable in practice: both callers gate on document_url?,
        # which already parsed this exact string.
        nil
      end

      # A trailing-dot host is the same DNS name as the bare one, but
      # TLS/SNI is presented as "grok.com." and fails. Do not strip the
      # dot and fetch: that packet is wasted, and writing the per-host
      # failure key under the chomped name would poison grok.com.
      def trailing_dot_host?(uri)
        uri.host.to_s.end_with?(".")
      end

      # "MUST NOT contain single-dot or double-dot path components" —
      # draft-ietf-oauth-client-id-metadata-document-02 §3. Shape
      # reject, no packet.
      def dot_path_segments?(uri)
        uri.path.to_s.split("/").any? { |segment| segment == "." || segment == ".." }
      end
    end
  end
end
