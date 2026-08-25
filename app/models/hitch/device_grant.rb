# frozen_string_literal: true

module Hitch
  # RFC 8628 device authorization grant. Lifecycle:
  #
  #   pending   — codes minted, awaiting a person on /activate
  #     ↓ approve! (binds the signed-in principal) | deny!
  #   approved | denied
  #     ↓ exchange_device_code! — the polling client's next request
  #   consumed  — an access token minted through the real exchange path
  #
  # Every transition is one conditional UPDATE whose WHERE clause is the
  # guard, the same discipline as the authorization-code exchange: the
  # database picks exactly one winner and no half-decided state — approved
  # but unowned, consumed twice — is ever representable.
  class DeviceGrant < ApplicationRecord
    self.table_name = "hitch_device_grants"

    # Crockford base32: RFC 8628 §6.1 wants no easily-confused characters,
    # and this alphabet drops I, L, O, U while its decoding treats the
    # survivors' look-alikes as equal. Eight characters is 40 bits, which
    # together with the per-principal verification quota clears the §5.1
    # brute-force bar with room to spare.
    USER_CODE_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    USER_CODE_LENGTH = 8
    TOKEN_ENDPOINT_AUTH_METHODS = %w[none client_secret_basic].freeze

    # The token endpoint already rescues AccessToken::OAuthError; a second
    # error type would only mean a second rescue.
    OAuthError = Hitch::AccessToken::OAuthError

    belongs_to :principal, polymorphic: true, optional: true

    # Raw codes surface once, in the mint response; only digests are at rest.
    attr_accessor :raw_device_code, :raw_user_code

    validates :device_code_digest, :user_code_digest, presence: true, on: :create
    validates :token_endpoint_auth_method, inclusion: { in: TOKEN_ENDPOINT_AUTH_METHODS }

    scope :pending, -> {
      where(approved_at: nil, denied_at: nil, consumed_at: nil)
        .where("expires_at > ?", Time.current)
    }

    # Scopes are clamped here, at mint — every caller's, not just the
    # endpoint's — so what a grant holds is always grantable and the
    # exchange can honor it verbatim.
    def self.mint!(client_id:, scopes:, resource_uri:, token_endpoint_auth_method: nil)
      granted = Hitch.configuration.clamp_scopes(scopes)
      token_endpoint_auth_method ||= authentication_method_for(client_id)
      attempts = 0
      begin
        # Both codes regenerate on retry, so whichever unique constraint
        # tripped, the next attempt is genuinely fresh.
        raw_device_code = SecureRandom.urlsafe_base64(32)
        raw_user_code = generate_user_code
        # requires_new: the retry below must survive a collision inside a
        # host's open transaction — on PostgreSQL a failed INSERT poisons
        # the enclosing transaction without a savepoint, turning the retry
        # into the very 500 it exists to prevent.
        record = transaction(requires_new: true) do
          create!(
            client_id: client_id,
            device_code_digest: Digest::SHA256.hexdigest(raw_device_code),
            user_code_digest: Digest::SHA256.hexdigest(raw_user_code),
            scopes: granted,
            resource_uri: resource_uri,
            token_endpoint_auth_method: token_endpoint_auth_method,
            expires_at: Hitch.configuration.device_code_lifetime_seconds.seconds.from_now
          )
        end
      rescue ActiveRecord::RecordNotUnique
        # Forty-bit user codes will eventually land on a live pending one.
        # Retrying keeps the collision invisible; giving up would turn an
        # unauthenticated 500 into a collision oracle.
        attempts += 1
        retry if attempts < 3
        raise
      end
      record.raw_device_code = raw_device_code
      record.raw_user_code = raw_user_code
      record
    end

    # Canonical form: the eight alphabet characters. Strips the punctuation
    # display adds, uppercases, and maps the look-alikes Crockford base32
    # deliberately treats as equal (§6.1 — the user's input is normalized,
    # never rejected for a dash or a lowercase letter).
    def self.normalize_user_code(input)
      input.to_s.upcase.gsub(/[^0-9A-Z]/, "").tr("OIL", "011")
    end

    # XXXX-XXXX, the form mint responses and screens show. Accepts sloppy
    # input; normalization is a no-op on canonical codes.
    def self.display_user_code(input)
      normalize_user_code(input).scan(/.{1,4}/).join("-")
    end

    def self.find_pending_by_user_code(input)
      normalized = normalize_user_code(input)
      return nil unless normalized.length == USER_CODE_LENGTH

      pending.find_by(user_code_digest: Digest::SHA256.hexdigest(normalized))
    end

    # The decision, its owner, and the user code's erasure land in one
    # statement: a grant is never approved-but-unowned, a second decision
    # finds nothing to decide, and only still-pending grants keep a
    # guessable code alive. Returns false when the code already met a
    # decision, expired, or never existed.
    def self.approve!(user_code:, principal:, client_name: nil)
      raise ArgumentError, "principal must be persisted" unless principal&.persisted?

      decide!(
        user_code, :approved_at,
        principal_type: principal.class.polymorphic_name,
        principal_id: principal.id,
        client_name: client_name
      )
    end

    def self.deny!(user_code:)
      decide!(user_code, :denied_at)
    end

    # The poll (RFC 8628 §3.4). Raises the §3.5 responses as OAuthError so
    # the token endpoint's existing rescue renders them; nil is the generic
    # invalid_grant, deliberately covering "never existed", "already
    # consumed", and "lost the race" alike.
    def self.exchange_device_code!(raw_device_code:, client_id:, resource_uri:, token_endpoint_auth_method:)
      unless Hitch.configuration.device_authorization_enabled
        raise OAuthError.new("unsupported_grant_type", "Device authorization is not enabled")
      end

      record = find_by(device_code_digest: Digest::SHA256.hexdigest(raw_device_code.to_s))
      return nil unless record

      unless record.client_id == client_id
        raise OAuthError.new("invalid_grant", "Device code was not issued to this client")
      end
      unless record.token_endpoint_auth_method == token_endpoint_auth_method
        raise ClientAuthentication::Invalid.new(
          "invalid_client", "Client authentication failed", http_status: :unauthorized
        )
      end
      unless record.resource_uri == resource_uri
        raise OAuthError.new("invalid_target", "resource does not match the authorized resource")
      end

      # Before expiry, deliberately: a person's "no" answers access_denied
      # however old the grant is. expired_token invites the client to start
      # the flow over (§3.5), which is not what the person said.
      if record.denied_at
        raise OAuthError.new("access_denied", "The request was denied")
      end

      now = Time.current
      if record.expires_at <= now
        raise OAuthError.new("expired_token", "Device code expired")
      end

      if record.approved_at
        # The approver may since have been deleted by the host. Consent does
        # not outlive its owner; the grant is dead, not the server.
        return nil if record.principal.nil?

        return consume!(record, now: now)
      end

      # §3.5: one poll per interval claims the window; the rest hear
      # slow_down. A rejected poll matches zero rows and writes nothing,
      # so it never advances the window — a client polling too fast is
      # throttled to the interval, not locked out. A little grace, scaled
      # so it can never halve the window: a conformant fixed-rate poller's
      # network jitter must not cost it the permanent +5s a slow_down
      # demands (§3.5) — the window bounds load, not guessing.
      interval = Hitch.configuration.device_authorization_interval_seconds
      window_opens = now - interval + [ 0.5, interval / 10.0 ].min
      claimed = where(id: record)
        .where("last_polled_at IS NULL OR last_polled_at <= ?", window_opens)
        .update_all(last_polled_at: now, updated_at: now)
      if claimed == 1
        raise OAuthError.new("authorization_pending", "The authorization request is still pending")
      end

      raise OAuthError.new("slow_down", "Polling faster than the interval")
    end

    # Rows are held a day past expiry so the §3.5 answer a polling client
    # hears — expired_token, or access_denied for a denied grant — does
    # not depend on when the host's cleanup job happens to run. Past the
    # floor the row goes: any token issued through it lives on in
    # hitch_access_tokens, which carries the durable audit trail. Same
    # host-scheduled contract as AccessToken.cleanup_expired!.
    def self.cleanup_expired!
      where("expires_at < ?", 1.day.ago).delete_all
    end

    def self.generate_user_code
      SecureRandom.alphanumeric(USER_CODE_LENGTH, chars: USER_CODE_ALPHABET.chars)
    end
    private_class_method :generate_user_code

    def self.authentication_method_for(client_id)
      client = Hitch::Client.find_by(client_id: client_id)
      client&.confidential_client? ? "client_secret_basic" : "none"
    end
    private_class_method :authentication_method_for

    def self.decide!(user_code, decision_column, attributes = {})
      digest = Digest::SHA256.hexdigest(normalize_user_code(user_code))
      now = Time.current
      pending.where(user_code_digest: digest).update_all(
        attributes.merge(decision_column => now, user_code_digest: nil, updated_at: now)
      ) == 1
    end
    private_class_method :decide!

    # requires_new for the same reason issue! gives: a bare transaction
    # joins any open one, and the consumption must roll back if the token
    # mint fails — a consumed grant with no token is a dead end.
    def self.consume!(record, now:)
      result = nil
      transaction(requires_new: true) do
        consumed = where(id: record.id, consumed_at: nil)
          .where.not(approved_at: nil)
          .update_all(consumed_at: now, device_code_digest: nil, updated_at: now)
        raise ActiveRecord::Rollback unless consumed == 1

        # The stored, mint-clamped scopes are issued verbatim — consent was
        # evaluated when it was given, and nothing re-litigates it here.
        _, result = Hitch::AccessToken.mint_through_exchange!(
          principal: record.principal,
          client_id: record.client_id,
          client_name: record.client_name.presence || record.client_id,
          resource_uri: record.resource_uri,
          scopes: record.scopes
        )
      end
      result
    end
    private_class_method :consume!
  end
end
