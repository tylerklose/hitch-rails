# frozen_string_literal: true

class AddHitchRefreshTokens < ActiveRecord::Migration[7.2]
  def change
    change_table :hitch_access_tokens, bulk: true do |t|
      # Same posture as every other secret here: the raw token is returned
      # once and only its SHA256 digest is at rest.
      t.string :refresh_token_digest
      # Idle window. Clamped at mint to the family ceiling, so one comparison
      # answers "still usable" and no caller has to remember the ceiling.
      t.datetime :refresh_expires_at
      # The reuse-detection evidence. A consumed row is what tells a replayed
      # token apart from a first use, so this is the one column cleanup must
      # not collect while the family it belongs to is still live.
      t.datetime :refresh_consumed_at

      # The lineage. Every rotation inserts a new row carrying the family_id
      # it descended from, so detecting one replay can revoke the whole line
      # in a single statement. Deliberately a grouping key and not a parent
      # pointer: revocation is family-wide, detection is per-digest, and
      # nothing reads the tree. A column is additive later and permanent now.
      t.string :family_id
      # Absolute ceiling, copied unchanged down the lineage. Carried on each
      # row rather than looked up from the root so rotation stays a single
      # write and outlives the root being collected.
      t.datetime :family_expires_at
    end

    add_index :hitch_access_tokens, :refresh_token_digest,
      unique: true, where: "refresh_token_digest IS NOT NULL"
    add_index :hitch_access_tokens, :family_id, where: "family_id IS NOT NULL"
  end
end
