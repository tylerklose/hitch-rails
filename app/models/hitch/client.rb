# frozen_string_literal: true

module Hitch
  # OAuth Dynamic Client Registration (RFC 7591) record. Captures the
  # human-readable client_name an MCP client sends during DCR so the
  # authorize flow can attribute records back to the originating
  # application (Claude Code, ChatGPT, Cursor, etc.).
  #
  # The client_name is attacker-controllable (anyone can POST to
  # /oauth/register with any client_name); consent UIs should NOT
  # trust it for display. Storage keeps it for audit fidelity.
  class Client < ApplicationRecord
    self.table_name = "hitch_clients"

    TOKEN_ENDPOINT_AUTH_METHODS = %w[none client_secret_basic].freeze
    CLIENT_SECRET_BYTES = 48
    MAX_CLIENT_ID_BYTES = 255
    MAX_CLIENT_NAME_BYTES = 255
    MAX_REDIRECT_URIS = 32
    MAX_REDIRECT_URI_BYTES = 255

    class InvalidRegistrationMetadata < ArgumentError; end

    # OpenID Connect Dynamic Client Registration 1.0 §2 defines exactly
    # these two. (Not RFC 7591 — that spec has no application_type; the
    # field is IANA-registered, which is how it rides along in an
    # otherwise RFC 7591 registration request.) A client sending anything
    # else is recorded as having declared nothing, rather than having its
    # registration rejected — see #normalize_application_type.
    APPLICATION_TYPES = %w[native web].freeze

    has_many :redirect_uri_records,
      class_name: "Hitch::ClientRedirectUri",
      foreign_key: :hitch_client_id,
      inverse_of: :client,
      dependent: :delete_all

    validates :client_id, presence: true, uniqueness: true
    validate :bounded_client_identifiers
    validates :application_type, inclusion: { in: APPLICATION_TYPES }, allow_nil: true
    validates :token_endpoint_auth_method, inclusion: { in: TOKEN_ENDPOINT_AUTH_METHODS }

    validate :secret_matches_auth_method

    def self.register!(client_id:, client_name:, redirect_uris:, application_type: nil)
      metadata = normalize_registration_metadata!(
        client_id: client_id,
        client_name: client_name,
        redirect_uris: redirect_uris
      )
      validate_application_type_shape!(application_type)

      transaction do
        client = create!(
          client_id: metadata.fetch(:client_id),
          client_name: metadata.fetch(:client_name),
          application_type: normalize_application_type(application_type),
          token_endpoint_auth_method: "none",
          operator_registered: false
        )
        client.replace_redirect_uris!(metadata.fetch(:redirect_uris))
        client
      end
    end

    def self.register_confidential!(
      client_id:,
      client_name:,
      redirect_uris:,
      application_type: nil,
      operator_registered: false
    )
      metadata = normalize_registration_metadata!(
        client_id: client_id,
        client_name: client_name,
        redirect_uris: redirect_uris
      )
      validate_application_type_shape!(application_type)
      raw_secret = generate_client_secret

      client = transaction do
        record = create!(
          client_id: metadata.fetch(:client_id),
          client_name: metadata.fetch(:client_name),
          application_type: normalize_application_type(application_type),
          token_endpoint_auth_method: "client_secret_basic",
          client_secret_digest: digest_secret(raw_secret),
          client_secret_issued_at: Time.current,
          operator_registered: operator_registered
        )
        record.replace_redirect_uris!(metadata.fetch(:redirect_uris))
        record
      end

      Credentials.new(client: client, client_secret: raw_secret)
    end

    # Unrecognized values become nil rather than a registration error.
    # `application_type` is recorded, never enforced (see the migration),
    # so a junk value costs nothing to drop — whereas rejecting the
    # registration would break a client over a field the server does not
    # yet act on. Absent and unrecognized are both "did not declare",
    # which is the honest reading of each.
    def self.normalize_application_type(value)
      value = value.to_s
      APPLICATION_TYPES.include?(value) ? value : nil
    end

    # Shared size and shape boundary for HTTP registration, operator tasks,
    # and direct framework callers. URI scheme policy remains protocol-level;
    # this method guarantees every persistence path is finite and lossless.
    # client_id is optional: HTTP registration mints one only after the
    # rest of the metadata is admitted, so it has nothing to validate here.
    def self.normalize_registration_metadata!(client_name:, redirect_uris:, client_id: nil)
      {
        client_id: client_id.nil? ? nil : bounded_string!(client_id, :client_id, max_bytes: MAX_CLIENT_ID_BYTES),
        client_name: client_name.nil? ? "MCP Client" :
          bounded_string!(client_name, :client_name, max_bytes: MAX_CLIENT_NAME_BYTES),
        redirect_uris: normalize_redirect_uris!(redirect_uris, allow_empty: false)
      }
    end

    def self.normalize_redirect_uris!(values, allow_empty: true)
      unless values.is_a?(Array) && (allow_empty || values.any?) && values.length <= MAX_REDIRECT_URIS
        raise InvalidRegistrationMetadata,
          "redirect_uris must be an array of #{allow_empty ? '0' : '1'}..#{MAX_REDIRECT_URIS} strings"
      end

      normalized = values.map do |value|
        bounded_string!(value, :redirect_uri, max_bytes: MAX_REDIRECT_URI_BYTES)
      end
      if normalized.uniq.length != normalized.length
        raise InvalidRegistrationMetadata, "redirect_uris must not contain duplicates"
      end

      normalized
    end

    def self.bounded_string!(value, field, max_bytes:)
      unless value.is_a?(String) && value.valid_encoding? && value.present? && value.bytesize <= max_bytes
        raise InvalidRegistrationMetadata, "#{field} must be a non-empty string of at most #{max_bytes} bytes"
      end

      value.dup
    end
    private_class_method :bounded_string!

    def self.validate_application_type_shape!(value)
      return if value.nil? || value.is_a?(String)

      raise InvalidRegistrationMetadata, "application_type must be a string"
    end
    private_class_method :validate_application_type_shape!

    def self.digest_secret(secret)
      Digest::SHA256.hexdigest(secret.to_s)
    end

    def self.generate_client_secret
      SecureRandom.urlsafe_base64(CLIENT_SECRET_BYTES)
    end

    def public_client?
      token_endpoint_auth_method == "none"
    end

    def confidential_client?
      token_endpoint_auth_method == "client_secret_basic"
    end

    def operator_registered_confidential_client?
      confidential_client? && operator_registered?
    end

    def authenticates_secret?(candidate)
      return false unless confidential_client? && client_secret_digest.present? && candidate.present?

      candidate_digest = self.class.digest_secret(candidate)
      ActiveSupport::SecurityUtils.secure_compare(client_secret_digest, candidate_digest)
    end

    def rotate_secret!
      raise ArgumentError, "public clients do not have a client secret" unless confidential_client?

      raw_secret = nil
      with_lock do
        raw_secret = self.class.generate_client_secret
        now = Time.current
        update!(
          client_secret_digest: self.class.digest_secret(raw_secret),
          client_secret_issued_at: now,
          client_secret_rotated_at: now
        )
      end
      Credentials.new(client: self, client_secret: raw_secret)
    end

    def redirect_uris
      redirect_uri_records.order(:uri).pluck(:uri)
    end

    # Works on new and persisted records alike: unpersisted clients build
    # association records that save with the parent; persisted clients
    # replace their rows atomically.
    def redirect_uris=(values)
      desired = self.class.normalize_redirect_uris!(values)
      if persisted?
        replace_redirect_uris!(desired)
      else
        self.redirect_uri_records = desired.map { |uri| Hitch::ClientRedirectUri.new(uri: uri) }
      end
    end

    def replace_redirect_uris!(values)
      desired = self.class.normalize_redirect_uris!(values)
      transaction do
        if desired.empty?
          redirect_uri_records.delete_all
        else
          redirect_uri_records.where.not(uri: desired).delete_all
        end
        existing = redirect_uri_records.where(uri: desired).pluck(:uri)
        (desired - existing).each { |uri| redirect_uri_records.create!(uri: uri) }
      end
      redirect_uris
    end

    private

    def secret_matches_auth_method
      if public_client?
        errors.add(:client_secret_digest, "must be absent for a public client") if client_secret_digest.present?
        errors.add(:client_secret_issued_at, "must be absent for a public client") if client_secret_issued_at.present?
        errors.add(:client_secret_rotated_at, "must be absent for a public client") if client_secret_rotated_at.present?
      elsif client_secret_digest.blank? || client_secret_issued_at.blank?
        errors.add(:client_secret_digest, "and issued_at are required for a confidential client")
      end

      if operator_registered? && !confidential_client?
        errors.add(:operator_registered, "requires a confidential client")
      end
    end

    def bounded_client_identifiers
      if client_id.is_a?(String) && client_id.bytesize > MAX_CLIENT_ID_BYTES
        errors.add(:client_id, "is too long (maximum is #{MAX_CLIENT_ID_BYTES} bytes)")
      end
      if client_name.is_a?(String) && client_name.bytesize > MAX_CLIENT_NAME_BYTES
        errors.add(:client_name, "is too long (maximum is #{MAX_CLIENT_NAME_BYTES} bytes)")
      end
    end
  end
end
