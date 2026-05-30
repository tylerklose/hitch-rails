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
        t.references :principal, polymorphic: true, null: false, index: true

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
        t.string :redirect_uris, array: true, default: [], null: false

        t.timestamps
      end
    end
  end
end
