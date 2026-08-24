# frozen_string_literal: true

class CreateHitchDeviceGrants < ActiveRecord::Migration[7.2]
  def change
    create_table :hitch_device_grants do |t|
      t.string :client_id, null: false
      # Audit only, written at approval. Attacker-controllable in both
      # registration schemes, so nothing displays it as an identity.
      t.string :client_name

      # Raw codes are returned once at mint; only SHA256 digests are at
      # rest — the same posture as authorization codes. Both nullable on
      # purpose: the user code is erased in the same statement that
      # approves or denies, and the device code in the one that consumes,
      # so only grants still awaiting that step occupy the guessable
      # namespace and its unique index.
      t.string :device_code_digest,
        index: { unique: true, where: "device_code_digest IS NOT NULL" }
      t.string :user_code_digest,
        index: { unique: true, where: "user_code_digest IS NOT NULL" }

      # Nullable, unlike every other principal column in this schema: a
      # device grant is minted by an unauthenticated machine and owned by
      # nobody until a signed-in person approves it. String-typed for the
      # same lossless UUID/ULID reason as hitch_access_tokens. Unindexed:
      # nothing queries grants by principal — rows live minutes, and the
      # durable per-principal audit trail is hitch_access_tokens.
      t.references :principal, polymorphic: true, type: :string, null: true, index: false

      t.string :scopes, null: false, default: "mcp"
      t.string :resource_uri, null: false

      # Indexed for cleanup_expired!, this table's one non-digest query.
      t.datetime :expires_at, null: false, index: true
      # The state machine: pending is all four null. Each is written by a
      # single conditional UPDATE whose WHERE clause is the guard, so a
      # grant can never be half-decided or decided twice.
      t.datetime :approved_at
      t.datetime :denied_at
      t.datetime :consumed_at
      # RFC 8628 §3.5: the poll that claimed the current interval window.
      t.datetime :last_polled_at

      t.timestamps
    end
  end
end
