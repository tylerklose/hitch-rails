# frozen_string_literal: true

class NormalizeHitchClientRedirectUris < ActiveRecord::Migration[7.1]
  REDIRECT_STATE_KEY = "redirect_uris"

  class UnsupportedLegacyRedirectStorage < StandardError; end

  def up
    legacy_install = column_exists?(:hitch_clients, :redirect_uris)
    ensure_supported_legacy_storage! if legacy_install

    create_redirect_uri_table unless table_exists?(:hitch_client_redirect_uris)
    create_schema_state_table unless table_exists?(:hitch_schema_states)
    backfill_legacy_redirects if legacy_install
    seed_redirect_state(legacy_install ? 1 : 2)
    validate_redirect_state!(legacy_install: legacy_install)
  end

  def down
    # On a fresh install the original Hitch migration owns these tables and
    # this additive migration was a no-op. Never drop fresh-owned data while
    # reversing the upgrade step.
    return unless column_exists?(:hitch_clients, :redirect_uris)

    if table_exists?(:hitch_schema_states)
      version = redirect_state_rows.one? && redirect_state_rows.first.fetch("version").to_i
      unless version == 1
        raise ActiveRecord::IrreversibleMigration,
          "run hitch:redirects:prepare_rollback before reversing normalized redirect storage"
      end
    end

    drop_table :hitch_client_redirect_uris, if_exists: true
    drop_table :hitch_schema_states, if_exists: true
  end

  private

  def create_redirect_uri_table
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

  def create_schema_state_table
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

  def backfill_legacy_redirects
    execute <<~SQL.squish
      INSERT INTO hitch_client_redirect_uris
        (hitch_client_id, uri, created_at, updated_at)
      SELECT hitch_clients.id, redirect_uri, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM hitch_clients
      CROSS JOIN LATERAL unnest(hitch_clients.redirect_uris) AS redirect_uri
      WHERE redirect_uri IS NOT NULL AND btrim(redirect_uri) <> ''
      ON CONFLICT (hitch_client_id, uri) DO NOTHING
    SQL
  end

  def seed_redirect_state(version)
    quoted_key = connection.quote(REDIRECT_STATE_KEY)
    return if select_value("SELECT 1 FROM hitch_schema_states WHERE key = #{quoted_key} LIMIT 1")

    execute <<~SQL.squish
      INSERT INTO hitch_schema_states (key, version, created_at, updated_at)
      VALUES (#{quoted_key}, #{connection.quote(version)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def ensure_supported_legacy_storage!
    return if connection.adapter_name == "PostgreSQL"

    raise UnsupportedLegacyRedirectStorage,
      "legacy redirect_uris arrays can only be upgraded from PostgreSQL"
  end

  def validate_redirect_state!(legacy_install:)
    rows = redirect_state_rows
    unless rows.one?
      raise "expected exactly one #{REDIRECT_STATE_KEY.inspect} schema state row, found #{rows.length}"
    end

    version = rows.first.fetch("version").to_i
    allowed = legacy_install ? [ 1, 2 ] : [ 2 ]
    return if allowed.include?(version)

    raise "invalid #{REDIRECT_STATE_KEY.inspect} schema state version #{version.inspect}"
  end

  def redirect_state_rows
    quoted_key = connection.quote(REDIRECT_STATE_KEY)
    select_all(<<~SQL.squish).to_a
      SELECT version
      FROM hitch_schema_states
      WHERE key = #{quoted_key}
      LIMIT 2
    SQL
  end
end
