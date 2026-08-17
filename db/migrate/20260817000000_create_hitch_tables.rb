# frozen_string_literal: true

class CreateHitchTables < ActiveRecord::Migration[7.2]
  def change
    create_table :hitch_access_tokens do |t|
      # Polymorphic principals may use integer, UUID, ULID, or other
      # string-shaped primary keys. A numeric foreign-key column silently
      # truncates those values on SQLite and rejects them on PostgreSQL, so
      # keep the shared representation lossless and let each principal model
      # cast its own primary key when Rails resolves the association.
      t.references :principal, polymorphic: true, type: :string, null: false, index: true

      t.string :client_id, null: false
      t.string :client_name

      # The raw authorization code is returned to the client once, in the
      # OAuth redirect; only its SHA256 digest is at rest — the same
      # posture as bearer tokens.
      t.string :authorization_code_digest,
        index: { unique: true, where: "authorization_code_digest IS NOT NULL" }
      t.datetime :code_expires_at
      t.string :redirect_uri

      t.string :code_challenge, null: false
      t.string :code_challenge_method, null: false, default: "S256"

      t.string :token_digest, index: { unique: true, where: "token_digest IS NOT NULL" }
      t.datetime :expires_at
      t.datetime :revoked_at

      t.string :resource_uri
      t.string :scopes, null: false, default: "mcp"

      t.timestamps
    end

    create_table :hitch_clients do |t|
      t.string :client_id, null: false, index: { unique: true }
      t.string :client_name, null: false

      # OpenID Connect DCR 1.0 §2. Nullable and deliberately NOT defaulted
      # to "web": NULL means "did not declare", which is the fact worth
      # recording — a future decision to gate loopback redirects on
      # application_type must be able to see who actually said "native".
      t.string :application_type

      t.string :token_endpoint_auth_method, null: false, default: "none"
      t.string :client_secret_digest
      t.datetime :client_secret_issued_at
      t.datetime :client_secret_rotated_at

      t.timestamps

      t.check_constraint "token_endpoint_auth_method IN ('none', 'client_secret_basic')",
        name: "hitch_clients_auth_method_check"
      t.check_constraint <<~SQL.squish, name: "hitch_clients_secret_consistency_check"
        (token_endpoint_auth_method = 'none' AND client_secret_digest IS NULL AND client_secret_issued_at IS NULL AND client_secret_rotated_at IS NULL)
        OR
        (token_endpoint_auth_method = 'client_secret_basic' AND client_secret_digest IS NOT NULL AND client_secret_issued_at IS NOT NULL)
      SQL
    end

    create_table :hitch_client_redirect_uris do |t|
      t.references :hitch_client,
        null: false,
        index: false,
        foreign_key: { to_table: :hitch_clients, on_delete: :cascade }
      t.string :uri, null: false

      t.timestamps

      t.index [ :hitch_client_id, :uri ],
        unique: true,
        name: "index_hitch_client_redirect_uris_on_client_and_uri"
    end
  end
end
