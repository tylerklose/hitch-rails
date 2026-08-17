# frozen_string_literal: true

require "digest"

module Hitch
  class ClientIdMetadata
    # Rails.cache storage for resolved documents and failure negatives.
    # A cache outage must not take the authorize endpoint with it: every
    # operation degrades to a miss.
    module Cache
      # Cached negatives are deliberately short-lived relative to positives:
      # long enough that a hostile URL cannot drive one fetch per request,
      # short enough that a client fixing a genuinely broken document isn't
      # locked out for an hour.
      FAILURE_TTL = 60

      module_function

      # Versioned so a change to Document's shape invalidates old entries
      # instead of colliding with them.
      def key(client_id)
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

      def read(key)
        Rails.cache.read(key)
      rescue StandardError
        nil
      end

      def write(key, value, ttl)
        Rails.cache.write(key, value, expires_in: ttl)
      rescue StandardError
        nil
      end

      def delete(key)
        Rails.cache.delete(key)
      rescue StandardError
        nil
      end
    end
  end
end
