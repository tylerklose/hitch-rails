# frozen_string_literal: true

module Hitch
  # OAuth 2.1 access token + authorization code record. Lifecycle:
  #
  #   pending   — code minted, awaiting POST /oauth/token exchange
  #     ↓ consume_code!(code_verifier) — PKCE-verified
  #   active    — token_digest set; usable until expires_at or revoked_at
  #     ↓ revoke! / expiry
  #   inactive
  #
  # Polymorphic principal: host apps configure Hitch.principal_model
  # but each row records which model type owns the token via
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
    # consent — e.g. `token.has_scope?("write")` before mutating ops.
    def has_scope?(scope)
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

    # Lookup by raw auth code value — hashes inbound to compare against
    # the stored digest. Returns the pending row or nil. The atomic
    # FOR UPDATE SKIP LOCKED in the token controller still wraps this.
    def self.find_pending_by_code(raw_code)
      return nil if raw_code.blank?

      pending.find_by(authorization_code_digest: Digest::SHA256.hexdigest(raw_code))
    end

    def consume_code!(code_verifier)
      verify_pkce!(code_verifier)
      raw_token = SecureRandom.urlsafe_base64(32)
      update!(
        token_digest: Digest::SHA256.hexdigest(raw_token),
        authorization_code_digest: nil,
        code_expires_at: nil,
        expires_at: Hitch.configuration.access_token_lifetime_seconds.seconds.from_now
      )
      raw_token
    end

    def revoke!
      update!(revoked_at: Time.current)
    end

    def self.find_by_token(raw_token)
      return nil if raw_token.blank?

      active.find_by(token_digest: Digest::SHA256.hexdigest(raw_token))
    end

    # Operational cleanup. Two classes of rows accumulate that nothing
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
    # Per the 2025-11-25 MCP authorization spec: "MCP servers MUST
    # validate that access tokens were issued specifically for them
    # as the intended audience."
    # Spec URL: https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization
    def valid_for_resource?(resource_uri)
      return false if resource_uri.blank?

      self.resource_uri.present? && self.resource_uri == resource_uri
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
