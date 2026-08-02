# frozen_string_literal: true

# Host apps adopting hitch-rails for the first time get fresh tables.
# create_table is skipped when a destination table already exists, so an
# app that supplies its own migration to reshape pre-existing data (e.g.
# when adopting the gem over a prior in-house implementation) doesn't
# collide with this one.
class CreateHitchTables < ActiveRecord::Migration[7.1]
  def change
    unless table_exists?(:hitch_access_tokens)
      create_table :hitch_access_tokens do |t|
        # Polymorphic principals may use integer, UUID, ULID, or other
        # string-shaped primary keys. A numeric foreign-key column silently
        # truncates those values on SQLite and rejects them on PostgreSQL, so
        # keep the shared representation lossless and let each principal model
        # cast its own primary key when Rails resolves the association.
        t.references :principal, polymorphic: true, type: :string, null: false, index: true

        t.string :client_id, null: false
        t.string :client_name

        t.string :authorization_code, index: { unique: true, where: "authorization_code IS NOT NULL" }
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
    end

    unless table_exists?(:hitch_clients)
      create_table :hitch_clients do |t|
        t.string :client_id, null: false, index: { unique: true }
        t.string :client_name, null: false

        t.timestamps
      end
    end

    unless table_exists?(:hitch_client_redirect_uris)
      create_table :hitch_client_redirect_uris do |t|
        t.references :hitch_client,
          null: false,
          index: false,
          foreign_key: { to_table: :hitch_clients, on_delete: :cascade }
        t.string :uri, null: false
        t.timestamps
      end

      add_index :hitch_client_redirect_uris,
        [ :hitch_client_id, :uri ],
        unique: true,
        name: "index_hitch_client_redirect_uris_on_client_and_uri"
    end

    unless table_exists?(:hitch_schema_states)
      create_table :hitch_schema_states do |t|
        t.string :key, null: false
        t.integer :version, null: false
        t.timestamps
      end

      add_index :hitch_schema_states, :key, unique: true
      add_check_constraint :hitch_schema_states,
        "version IN (1, 2)",
        name: "hitch_schema_states_version_check"
    end

    up_only do
      key = connection.quote("redirect_uris")
      unless select_value("SELECT 1 FROM hitch_schema_states WHERE key = #{key} LIMIT 1")
        execute <<~SQL.squish
          INSERT INTO hitch_schema_states (key, version, created_at, updated_at)
          VALUES (#{key}, 2, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
      end
    end
  end
end
