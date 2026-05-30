# frozen_string_literal: true

# Authorization codes follow the same security posture as bearer tokens:
# raw value returned to the client once (in the OAuth redirect), only
# the SHA256 digest persisted in the DB. This is defense-in-depth, not
# a directly-exploitable hole under mandatory S256 PKCE: the DB stores
# the code_challenge, never the code_verifier, so a stolen pending code
# alone cannot be redeemed. The value is consistency with bearer-token
# hashing and shrinking the blast radius of a DB read (one fewer secret
# at rest), within the code's short 10-minute TTL.
#
# Existing pending codes are unredeemable after this migration. Auth
# codes are short-lived (10 min default) and clients retry the OAuth
# dance on failure — graceful invalidation, not a disruption surface.
class HashAuthorizationCodes < ActiveRecord::Migration[7.1]
  def up
    rename_column :hitch_access_tokens, :authorization_code, :authorization_code_digest

    # Existing rows hold raw codes (or are NULL after consume). Invalidate
    # them all — they're either pending (will be retried) or already
    # consumed (digest is meaningless for consumed rows).
    execute "UPDATE hitch_access_tokens SET authorization_code_digest = NULL"
  end

  def down
    # Plaintext rollback loses the digests (cannot recover originals).
    # Equivalent to a mass-revoke of pending codes on rollback too.
    execute "UPDATE hitch_access_tokens SET authorization_code_digest = NULL"
    rename_column :hitch_access_tokens, :authorization_code_digest, :authorization_code
  end
end
