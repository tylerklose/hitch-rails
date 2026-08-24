# frozen_string_literal: true

module Hitch
  # Shared mechanics for controller admission that must run before Rails
  # instrumentation parses request parameters. Policy remains in the endpoint-
  # specific concerns.
  module RequestAdmission
    extend ActiveSupport::Concern

    # Default cap on request bodies for the OAuth endpoints. Read via
    # `self.class::MAX_REQUEST_BODY_BYTES`, so a controller may override
    # it with its own constant.
    MAX_REQUEST_BODY_BYTES = 16_384

    private

    def hitch_read_bounded_request_body(max_bytes)
      stream = request.body
      stream.rewind if stream.respond_to?(:rewind)
      limit = max_bytes + 1
      bytes = +"".b

      # Rack inputs may return a short chunk without being at EOF. Continue
      # until EOF or the cap sentinel instead of treating one short read as the
      # complete trusted body.
      while bytes.bytesize < limit
        chunk = stream.read(limit - bytes.bytesize)
        break if chunk.nil? || chunk.empty?

        bytes << chunk.to_s.b
      end
      return if bytes.bytesize > max_bytes

      # Rack does not require rack.input to implement rewind. Rails replays a
      # cached RAW_POST_DATA value through StringIO, so accepted bytes remain
      # available to request.raw_post and any later consumer without touching
      # the original stream a second time.
      request.set_header("RAW_POST_DATA", bytes)
      bytes
    end

    def finalize_hitch_admission_rejection!
      set_cors_headers if respond_to?(:set_cors_headers, true)
    end

    # RFC 6749 §5.1: responses carrying credentials are never cacheable.
    # Pragma for the HTTP/1.0 caches still out there.
    def hitch_no_store!
      response.headers["Cache-Control"] = "no-store"
      response.headers["Pragma"] = "no-cache"
    end

    # One JSON mapping for a fixed-window refusal, shared by every counted
    # machine endpoint: 429 with Retry-After when counted out, 503 when the
    # store cannot count. Yields to the limiter; returns whether to proceed.
    def hitch_admit_rate!(activity)
      yield
      true
    rescue Hitch::RateLimitStore::Exceeded => error
      response.headers["Retry-After"] = error.retry_after.to_s
      oauth_error("temporarily_unavailable", "#{activity} rate limit exceeded", :too_many_requests)
      false
    rescue Hitch::RateLimitStore::Unavailable
      oauth_error("temporarily_unavailable", "#{activity} is temporarily unavailable", :service_unavailable)
      false
    end
  end
end
