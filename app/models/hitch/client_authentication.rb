# frozen_string_literal: true

module Hitch
  class ClientAuthentication
    MAX_AUTHORIZATION_BYTES = 4_096
    MAX_SECRET_BYTES = 512
    CONTROL_CHARACTERS = /[\u0000-\u001F\u007F-\u009F]/
    Resolution = Data.define(
      :client_id,
      :token_endpoint_auth_method,
      :registered_client,
      :operator_registered
    )

    class Invalid < StandardError
      attr_reader :oauth_code, :http_status

      def initialize(oauth_code, message, http_status: :bad_request)
        @oauth_code = oauth_code
        @http_status = http_status
        super(message)
      end
    end

    def self.resolve(request:, body_client_id:, body_secret_present:)
      authorization = request.headers["Authorization"].to_s
      return public_client_id(body_client_id, body_secret_present:) if authorization.blank?

      raise Invalid.new("invalid_request", "client_secret is not accepted in the request body") if body_secret_present

      client_id, secret = decode_basic(authorization)
      invalid_client! if body_client_id.present? && body_client_id != client_id

      client = Hitch::Client.find_by(client_id: client_id)
      invalid_client! unless client&.authenticates_secret?(secret)

      Resolution.new(
        client_id:,
        token_endpoint_auth_method: "client_secret_basic",
        registered_client: true,
        operator_registered: client.operator_registered?
      )
    end

    def self.public_client_id(client_id, body_secret_present:)
      raise Invalid.new("invalid_request", "client_secret is not accepted in the request body") if body_secret_present
      raise Invalid.new("invalid_request", "client_id is required") if client_id.blank?
      invalid_client! unless valid_component?(client_id, max_bytes: Hitch::Client::MAX_CLIENT_ID_BYTES)

      client = Hitch::Client.find_by(client_id: client_id)
      invalid_client! if client&.confidential_client?

      Resolution.new(
        client_id:,
        token_endpoint_auth_method: "none",
        registered_client: client.present?,
        operator_registered: false
      )
    end
    private_class_method :public_client_id

    def self.decode_basic(authorization)
      invalid_client! if authorization.bytesize > MAX_AUTHORIZATION_BYTES

      scheme, encoded = authorization.split(" ", 2)
      invalid_client! unless scheme&.casecmp?("Basic") && encoded.present? && !encoded.match?(/\s/)

      decoded = Base64.strict_decode64(encoded)
      encoded_client_id, encoded_secret = decoded.split(":", 2)
      invalid_client! if encoded_client_id.blank? || encoded_secret.nil?

      client_id = URI.decode_www_form_component(encoded_client_id).encode(Encoding::UTF_8)
      secret = URI.decode_www_form_component(encoded_secret).encode(Encoding::UTF_8)
      invalid_client! unless valid_component?(client_id, max_bytes: Hitch::Client::MAX_CLIENT_ID_BYTES) &&
        valid_component?(secret, max_bytes: MAX_SECRET_BYTES)

      [ client_id, secret ]
    # Base64, URI decoding, and encoding conversion raise these for malformed
    # credentials; they collapse to the same uniform refusal.
    rescue ArgumentError, EncodingError
      invalid_client!
    end
    private_class_method :decode_basic

    def self.invalid_client!
      raise Invalid.new("invalid_client", "Client authentication failed", http_status: :unauthorized)
    end
    private_class_method :invalid_client!

    def self.valid_component?(value, max_bytes:)
      value.is_a?(String) && value.valid_encoding? && value.present? &&
        value.bytesize <= max_bytes && !value.match?(CONTROL_CHARACTERS)
    end
    private_class_method :valid_component?
  end
end
