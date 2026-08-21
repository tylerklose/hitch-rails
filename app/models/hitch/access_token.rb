# frozen_string_literal: true

module Hitch
  # OAuth 2.1 access token + authorization code record. Lifecycle:
  #
  #   pending   — code minted, awaiting POST /oauth/token exchange
  #     ↓ exchange_authorization_code! — all bindings verified, then atomically consumed
  #   active    — token_digest set; usable until expires_at or revoked_at
  #     ↓ revoke! / expiry
  #   inactive
  #
  # Polymorphic principal: the host controller supplies the signed-in
  # record, and each row records which model type owns the token via
  # principal_type + principal_id (standard Rails polymorphic).
  #
  # RFC 8707: resource_uri is the audience this token was issued for.
  # The MCP server validates at token use time that the request's
  # resource matches token.resource_uri.
  class AccessToken < ApplicationRecord
    self.table_name = "hitch_access_tokens"

    class OAuthError < StandardError
      attr_reader :oauth_code, :description

      def initialize(oauth_code, description)
        @oauth_code = oauth_code
        @description = description
        super(description)
      end
    end

    belongs_to :principal, polymorphic: true

    # Raw authorization code is returned to the client via the OAuth
    # redirect once at issuance; the DB only ever holds the SHA256
    # digest. This attr_accessor lets create_authorization! surface the
    # raw code to the controller without persisting it.
    attr_accessor :raw_authorization_code

    scope :pending, -> { where(token_digest: nil).where("code_expires_at > ?", Time.current) }
    scope :active,  -> { where.not(token_digest: nil).where(revoked_at: nil).where("expires_at > ?", Time.current) }

    validates :code_challenge, presence: true
    validates :code_challenge, format: { with: Hitch::Pkce::S256_CHALLENGE }
    validates :code_challenge_method, inclusion: { in: %w[S256] }

    def expired?
      expires_at.present? && expires_at < Time.current
    end

    def revoked?
      revoked_at.present?
    end

    def accessible?
      token_digest.present? && !expired? && !revoked?
    end

    # Space-delimited scope check per OAuth 2.1 §3.3. Hosts call this to
    # gate operations behind a specific scope the client requested at
    # consent — e.g. `token.scope?("write")` before mutating ops.
    def scope?(scope)
      return false if scopes.blank? || scope.blank?

      scopes.split(/\s+/).include?(scope.to_s)
    end

    def self.create_authorization!(principal:, client_id:, client_name:, code_challenge:, code_challenge_method:, scopes: "mcp", redirect_uri: nil, resource_uri: nil)
      raw_code = SecureRandom.urlsafe_base64(32)
      record = create!(
        principal: principal,
        client_id: client_id,
        client_name: client_name,
        redirect_uri: redirect_uri,
        resource_uri: resource_uri,
        authorization_code_digest: Digest::SHA256.hexdigest(raw_code),
        code_challenge: code_challenge,
        code_challenge_method: code_challenge_method,
        code_expires_at: Hitch.configuration.authorization_code_lifetime_seconds.seconds.from_now,
        scopes: scopes
      )
      record.raw_authorization_code = raw_code
      record
    end

    # Mints a usable access token outside the browser flow, for a headless
    # agent or a cron job that cannot complete a consent redirect. The
    # operator at a console with database access is both the resource owner
    # and the client, so there is no third party for a consent screen to
    # protect anyone from.
    #
    # Runs the real authorization-code exchange rather than writing a row
    # directly: the PKCE pair is generated and spent here, so the row that
    # lands is indistinguishable from a browser-issued one and the same code
    # path is proven by every other test in the suite. The token is returned
    # once and only its digest is stored, exactly as in the OAuth flow.
    def self.issue!(principal:, client_id:, client_name: nil, scopes: nil, expires_in: nil)
      unless client_id.is_a?(String) && !client_id.empty?
        # The endpoint refuses a token with a blank client_id, so issuing one
        # would hand back a credential that can never work.
        raise ArgumentError, "client_id must be a nonempty String"
      end
      # uniq like the browser flow's `asked & supported`, which cannot repeat
      # a scope past the persisted scope-set boundary.
      granted = Array(scopes).map(&:to_s).uniq.presence || [ Hitch.configuration.supported_scopes.first ]
      unsupported = granted - Hitch.configuration.supported_scopes
      unless unsupported.empty?
        raise ArgumentError,
          "scopes are not present in Hitch.configuration.supported_scopes: #{unsupported.join(', ')}"
      end
      # to_s first, then base 10: Integer(x, 10) rejects a non-String, and
      # without the base "0700" parses as octal 448.
      seconds = expires_in.nil? ? nil : Integer(expires_in.to_s, 10, exception: false)
      raise ArgumentError, "expires_in must be a positive number of seconds" if
        !expires_in.nil? && !seconds&.positive?

      resource_uri = Hitch.configuration.resource_uri
      verifier = SecureRandom.urlsafe_base64(64)
      # requires_new, not a plain transaction: a bare `transaction` JOINS a
      # caller's open one and opens no savepoint, so a host calling issue!
      # inside its own transaction and rescuing kept the very row this exists
      # to roll back.
      transaction(requires_new: true) do
        record = create_authorization!(
          principal: principal,
          client_id: client_id,
          client_name: client_name.presence || client_id,
          code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false),
          code_challenge_method: "S256",
          resource_uri: resource_uri,
          scopes: granted.join(" ")
        )
        result = exchange_authorization_code!(
          raw_code: record.raw_authorization_code,
          code_verifier: verifier,
          client_id: client_id,
          resource_uri: resource_uri
        )
        raise "Hitch could not issue an access token" if result.nil?

        # The exchange dates every token by the configured lifetime, which is
        # sized for a browser session. A headless agent asks for its own.
        record.reload.update!(expires_at: seconds.seconds.from_now) if seconds

        result.fetch(:raw_token)
      end
    end

    def self.exchange_authorization_code!(raw_code:, code_verifier:, client_id:, resource_uri:, redirect_uri: nil)
      unless Hitch::Pkce.valid_verifier?(code_verifier)
        raise OAuthError.new("invalid_grant", "PKCE verifier is malformed")
      end

      code_digest = Digest::SHA256.hexdigest(raw_code.to_s)
      record = pending.find_by(authorization_code_digest: code_digest)
      return nil unless record

      unless record.client_id == client_id
        raise OAuthError.new("invalid_grant", "Authorization code was not issued to this client")
      end
      # RFC 6749 §4.1.3: a redirect_uri sent to the token endpoint MUST be
      # identical to the one the code was issued to. Omitting it is legal
      # (OAuth 2.1 drops the parameter; PKCE carries the binding).
      if redirect_uri.present? && record.redirect_uri != redirect_uri
        raise OAuthError.new("invalid_grant", "redirect_uri does not match the authorization request")
      end
      unless record.resource_uri == resource_uri
        raise OAuthError.new("invalid_target", "resource does not match the authorized resource")
      end

      record.send(:verify_pkce!, code_verifier)
      raw_token = SecureRandom.urlsafe_base64(32)
      now = Time.current
      updated = where(
        id: record.id,
        authorization_code_digest: code_digest,
        token_digest: nil
      ).where("code_expires_at > ?", now).update_all(
        token_digest: Digest::SHA256.hexdigest(raw_token),
        authorization_code_digest: nil,
        code_expires_at: nil,
        expires_at: now + Hitch.configuration.access_token_lifetime_seconds.seconds,
        updated_at: now
      )

      return nil unless updated == 1

      { raw_token: raw_token, scope: record.scopes }
    end

    def revoke!
      update!(revoked_at: Time.current)
    end

    def self.find_by_token(raw_token)
      return nil if raw_token.blank?

      active.find_by(token_digest: Digest::SHA256.hexdigest(raw_token))
    end

    # Operational cleanup. Three classes of rows accumulate that nothing
    # ever reads again:
    #
    #   1) Pending auth codes whose code_expires_at < now — orphaned by
    #      OAuth flows the client abandoned (closed the browser, etc.).
    #      No token was issued; the row is unreachable.
    #   2) Revoked tokens older than `revoked_retention_days`. The
    #      record is kept for a window so audit logs/billing/etc. can
    #      look up the principal_id; beyond that, drop.
    #   3) Expired tokens (expires_at < now) older than
    #      `revoked_retention_days` — same audit-window argument.
    #
    # Returns the number of rows deleted. Idempotent.
    #
    # Hosts schedule this via whatever background job framework they
    # use (Solid Queue / GoodJob / Sidekiq / cron+rake — gem-agnostic).
    # Example:
    #
    #   class CleanupMCPTokensJob < ApplicationJob
    #     def perform
    #       Hitch::AccessToken.cleanup_expired!
    #     end
    #   end
    def self.cleanup_expired!(revoked_retention_days: 30)
      cutoff = revoked_retention_days.days.ago
      count = 0
      count += where(token_digest: nil).where("code_expires_at < ?", Time.current).delete_all
      count += where.not(revoked_at: nil).where("revoked_at < ?", cutoff).delete_all
      count += where.not(expires_at: nil).where("expires_at < ?", cutoff).delete_all
      count
    end

    # RFC 8707 audience validation. Returns false if the token was
    # issued for a different resource than the one currently asking.
    # Per the 2026-07-28 MCP authorization spec: "MCP servers MUST
    # validate that access tokens were issued specifically for them
    # as the intended audience."
    # Spec URL: https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization
    def valid_for_resource?(requested_resource_uri)
      allow_loopback = Rails.env.local?
      stored = ResourceUri.canonicalize!(resource_uri, allow_loopback_http: allow_loopback)
      requested = ResourceUri.canonicalize!(requested_resource_uri, allow_loopback_http: allow_loopback)
      stored == requested
    rescue ResourceUri::Invalid
      false
    end

    private

    def verify_pkce!(code_verifier)
      raise OAuthError.new("invalid_grant", "Authorization code expired") if code_expires_at.nil? || code_expires_at < Time.current

      expected = Base64.urlsafe_encode64(Digest::SHA256.digest(code_verifier), padding: false)
      return if ActiveSupport::SecurityUtils.secure_compare(expected, code_challenge)

      raise OAuthError.new("invalid_grant", "PKCE verification failed")
    end
  end
end
