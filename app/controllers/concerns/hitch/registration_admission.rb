# frozen_string_literal: true

require "json"

module Hitch
  # Dynamic Client Registration is an unauthenticated write endpoint. Rails'
  # controller instrumentation reads `request.filtered_parameters` before it
  # runs before_action callbacks, which means a callback cannot honestly cap,
  # rate-limit, or validate a JSON body before Rails parses it.
  #
  # This concern participates in ActionController's `process_action` chain one
  # level earlier. It admits the request, parses one bounded JSON document with
  # duplicate keys forbidden, and installs that verified Hash as Rails' cached
  # request parameters. Instrumentation and the action then reuse the same
  # object instead of parsing attacker-controlled input a second time.
  module RegistrationAdmission
    extend ActiveSupport::Concern

    include Hitch::RequestAdmission

    ADMITTED_HEADER = "hitch.registration_admitted"

    private

    def process_action(action_name, ...)
      return super unless action_name.to_s == "create"
      unless admit_registration_request!
        finalize_hitch_admission_rejection!
        return
      end

      super
    end

    def admit_registration_request!
      hitch_no_store!

      # Error rendering and host callbacks can consult `params`. Install an
      # empty body-parameter cache before either can accidentally invoke Rails'
      # JSON parser; a successful strict parse replaces it below.
      request.request_parameters = {}

      return false unless admit_registration_host!
      return false unless admit_registration_mode!
      return false unless admit_registration_media_type!
      return false unless admit_registration_rate!

      raw_body = bounded_registration_body
      return false if performed?

      metadata = JSON.parse(raw_body, allow_duplicate_key: false)
      unless metadata.is_a?(Hash)
        oauth_error("invalid_client_metadata", "registration metadata must be a JSON object")
        return false
      end

      request.request_parameters = metadata
      request.set_header(ADMITTED_HEADER, true)
      true
    rescue JSON::ParserError
      oauth_error("invalid_client_metadata", "request body must be valid JSON")
      false
    end

    def admit_registration_host!
      return true if hitch_request_origin_allowed?

      require_allowed_hitch_host!
      false
    end

    def admit_registration_mode!
      return true if Hitch.configuration.dynamic_client_registration_enabled

      head :not_found
      false
    end

    def admit_registration_media_type!
      return true if request.media_type == "application/json"

      oauth_error(
        "invalid_client_metadata",
        "Content-Type must be application/json",
        :unsupported_media_type
      )
      false
    end

    def admit_registration_rate!
      hitch_admit_rate!("Registration") do
        Hitch::DynamicRegistrationRateLimit.check!(remote_ip: request.remote_ip)
      end
    end

    def bounded_registration_body
      bytes = hitch_read_bounded_request_body(self.class::MAX_REQUEST_BODY_BYTES)
      return bytes if bytes

      oauth_error(
        "invalid_client_metadata",
        "registration request body exceeds #{self.class::MAX_REQUEST_BODY_BYTES} bytes",
        413
      )
      ""
    end
  end
end
