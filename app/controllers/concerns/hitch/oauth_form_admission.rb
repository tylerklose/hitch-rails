# frozen_string_literal: true

require "uri"

module Hitch
  # Rails records `request.filtered_parameters` before controller callbacks.
  # For OAuth form endpoints that would let Rack parse an unbounded credential
  # body before a conventional body-limit callback could run. This concern sits
  # earlier in the `process_action` chain, caps the raw stream, and installs a
  # deliberately minimal body-parameter cache for Rails instrumentation.
  #
  # Endpoint actions still parse the bounded raw form through
  # OauthRequestParameters, preserving duplicate and structured-key evidence.
  # The browser-backed consent POST retains only its CSRF token in Rails params;
  # public token and revocation endpoints expose no body fields to instrumentation.
  module OauthFormAdmission
    extend ActiveSupport::Concern

    include Hitch::RequestAdmission

    private

    def process_action(action_name, ...)
      if action_name.to_s == "create" && request.post?
        unless admit_oauth_form_request!
          finalize_hitch_admission_rejection!
          return
        end
      end

      super
    end

    def admit_oauth_form_request!
      prepare_oauth_form_response!
      request.request_parameters = {}
      unless hitch_request_origin_allowed?
        require_allowed_hitch_host!
        return false
      end
      return false unless admit_oauth_endpoint!

      raw_body = bounded_oauth_form_body
      return false if performed?

      request.request_parameters = hitch_instrumentation_form_parameters(raw_body)
      true
    end

    def bounded_oauth_form_body
      bytes = hitch_read_bounded_request_body(self.class::MAX_REQUEST_BODY_BYTES)
      return bytes if bytes

      reject_oversized_oauth_form_body!
      ""
    end

    def hitch_instrumentation_form_parameters(raw_body)
      return {} unless preserve_oauth_authenticity_token?

      values = raw_body.split("&").filter_map do |pair|
        encoded_key, encoded_value = pair.split("=", 2)
        next unless decode_form_component(encoded_key) == "authenticity_token"

        decode_form_component(encoded_value.to_s)
      end

      values.one? ? { "authenticity_token" => values.first } : {}
    end

    def decode_form_component(value)
      URI.decode_www_form_component(value)
    rescue ArgumentError
      nil
    end

    def preserve_oauth_authenticity_token?
      false
    end

    # Hook for endpoints that exist only behind a feature flag. Refusing
    # here answers before the body is read, so no endpoint-specific
    # body-cap error names a disabled feature. (The shared preflight and
    # host checks still answer for a disabled endpoint the way they do for
    # disabled registration — full indistinguishability is not claimed.)
    def admit_oauth_endpoint!
      true
    end

    def prepare_oauth_form_response!
    end
  end
end
