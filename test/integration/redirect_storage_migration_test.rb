# frozen_string_literal: true

require "test_helper"
require_relative "../support/redirect_storage_database"

class RedirectStorageMigrationTest < ActiveSupport::TestCase
  include RedirectStorageDatabase

  self.use_transactional_tests = false

  test "fresh schema is normalized, authoritative, reversible through the additive no-op, and retryable" do
    with_redirect_storage_database do |database|
      migrate_redirect_storage(database, CreateHitchTables, :up)

      assert_fresh_redirect_schema(database)

      migrate_redirect_storage(database, NormalizeHitchClientRedirectUris, :up)
      migrate_redirect_storage(database, NormalizeHitchClientRedirectUris, :down)

      assert_fresh_redirect_schema(database)

      migrate_redirect_storage(database, NormalizeHitchClientRedirectUris, :up)
      assert_fresh_redirect_schema(database)
    end
  end

  test "fresh migration chain keeps the authorization-code partial index valid across rename rollback" do
    with_redirect_storage_database do |database|
      [
        CreateHitchTables,
        HashAuthorizationCodes,
        AddApplicationTypeToHitchClients,
        NormalizeHitchClientRedirectUris,
        CascadeHitchClientRedirectDeletes,
        AddConfidentialCredentialsToHitchClients
      ].each do |migration|
        migrate_redirect_storage(database, migration, :up)
      end

      assert database.connection.column_exists?(:hitch_access_tokens, :authorization_code_digest)
      refute database.connection.column_exists?(:hitch_access_tokens, :authorization_code)
      assert_authorization_code_index(database, :authorization_code_digest)
      assert_fresh_redirect_schema(database)
      assert database.connection.column_exists?(:hitch_clients, :token_endpoint_auth_method)

      migrate_redirect_storage(database, HashAuthorizationCodes, :down)
      assert database.connection.column_exists?(:hitch_access_tokens, :authorization_code)
      refute database.connection.column_exists?(:hitch_access_tokens, :authorization_code_digest)
      assert_authorization_code_index(database, :authorization_code)

      migrate_redirect_storage(database, HashAuthorizationCodes, :up)
      assert_authorization_code_index(database, :authorization_code_digest)
    end
  end

  test "legacy PostgreSQL arrays backfill distinctly and survive rollback and retry" do
    with_redirect_storage_database do |database|
      create_legacy_clients_table(database)

      unless database.postgresql?
        error = assert_raises(NormalizeHitchClientRedirectUris::UnsupportedLegacyRedirectStorage) do
          migrate_redirect_storage(database, NormalizeHitchClientRedirectUris, :up)
        end
        assert_match(/only be upgraded from PostgreSQL/, error.message)
        refute database.connection.table_exists?(:hitch_client_redirect_uris)
        refute database.connection.table_exists?(:hitch_schema_states)
        next
      end

      legacy_client = Class.new(database.base) do
        self.table_name = "hitch_clients"
      end
      stored = [
        "https://b.example/callback",
        "https://a.example/callback",
        "https://b.example/callback",
        ""
      ]
      client = legacy_client.create!(
        client_id: "legacy-client",
        client_name: "Legacy",
        redirect_uris: stored
      )

      migrate_redirect_storage(database, NormalizeHitchClientRedirectUris, :up)

      assert_equal 1, redirect_state_version(database)
      assert_equal stored, client.reload.redirect_uris
      assert_equal(
        [ "https://a.example/callback", "https://b.example/callback" ],
        redirect_rows(database, client.id)
      )
      assert_cascading_redirect_foreign_key(database)

      migrate_redirect_storage(database, NormalizeHitchClientRedirectUris, :down)

      assert database.connection.table_exists?(:hitch_clients)
      refute database.connection.table_exists?(:hitch_client_redirect_uris)
      refute database.connection.table_exists?(:hitch_schema_states)
      assert_equal stored, client.reload.redirect_uris

      migrate_redirect_storage(database, NormalizeHitchClientRedirectUris, :up)

      assert_equal 1, redirect_state_version(database)
      assert_equal(
        [ "https://a.example/callback", "https://b.example/callback" ],
        redirect_rows(database, client.id)
      )
    end
  end

  test "additive migration rejects duplicate or impossible authority state" do
    with_redirect_storage_database do |database|
      database.connection.create_table :hitch_clients do |table|
        table.string :client_id, null: false
        table.string :client_name, null: false
        table.timestamps
      end
      database.connection.create_table :hitch_schema_states do |table|
        table.string :key, null: false
        table.integer :version, null: false
        table.timestamps
      end
      now = database.connection.quote(Time.current)
      database.connection.execute <<~SQL.squish
        INSERT INTO hitch_schema_states (key, version, created_at, updated_at)
        VALUES ('redirect_uris', 2, #{now}, #{now}), ('redirect_uris', 2, #{now}, #{now})
      SQL

      error = assert_raises(RuntimeError) do
        migrate_redirect_storage(database, NormalizeHitchClientRedirectUris, :up)
      end
      assert_match(/expected exactly one/, error.message)

      database.connection.execute("DELETE FROM hitch_schema_states")
      database.connection.execute <<~SQL.squish
        INSERT INTO hitch_schema_states (key, version, created_at, updated_at)
        VALUES ('redirect_uris', 1, #{now}, #{now})
      SQL

      error = assert_raises(RuntimeError) do
        migrate_redirect_storage(database, NormalizeHitchClientRedirectUris, :up)
      end
      assert_match(/invalid .* version 1/, error.message)
    end
  end

  test "runtime authority lookup fails closed on duplicate and invalid state" do
    with_redirect_storage_database do |database|
      database.connection.create_table :hitch_schema_states do |table|
        table.string :key, null: false
        table.integer :version, null: false
        table.timestamps
      end
      now = database.connection.quote(Time.current)
      database.connection.execute <<~SQL.squish
        INSERT INTO hitch_schema_states (key, version, created_at, updated_at)
        VALUES ('redirect_uris', 2, #{now}, #{now}), ('redirect_uris', 2, #{now}, #{now})
      SQL

      with_hitch_models_on(database) do
        error = assert_raises(Hitch::SchemaState::CorruptState) do
          Hitch::SchemaState.redirect_uris_version
        end
        assert_match(/exactly one/, error.message)

        Hitch::SchemaState.delete_all
        Hitch::SchemaState.connection.execute <<~SQL.squish
          INSERT INTO hitch_schema_states (key, version, created_at, updated_at)
          VALUES ('redirect_uris', 3, #{now}, #{now})
        SQL

        error = assert_raises(Hitch::SchemaState::CorruptState) do
          Hitch::SchemaState.redirect_uris_version
        end
        assert_match(/invalid .* version 3/, error.message)
      end
    end
  end

  private

  def assert_fresh_redirect_schema(database)
    assert database.connection.table_exists?(:hitch_client_redirect_uris)
    assert database.connection.table_exists?(:hitch_schema_states)
    refute database.connection.column_exists?(:hitch_clients, :redirect_uris)
    assert_equal 2, redirect_state_version(database)

    index = database.connection.indexes(:hitch_client_redirect_uris).find do |candidate|
      candidate.columns == %w[hitch_client_id uri]
    end
    assert index&.unique, "redirect URI composite index must be unique"
    assert_cascading_redirect_foreign_key(database)

    return unless database.sqlite?

    database_file = database.connection.select_rows("PRAGMA database_list").dig(0, 2)
    expected_file = File.realpath(File.join(database.temporary_path, "redirects.sqlite3"))
    assert_equal expected_file, File.realpath(database_file)
    refute_equal "", database_file
  end

  def assert_authorization_code_index(database, column)
    index = database.connection.indexes(:hitch_access_tokens).find do |candidate|
      candidate.columns == [ column.to_s ]
    end

    assert index&.unique, "authorization-code digest index must be unique"
    assert_includes index.where, "#{column} IS NOT NULL"
  end

  def assert_cascading_redirect_foreign_key(database)
    foreign_key = database.connection.foreign_keys(:hitch_client_redirect_uris).find do |candidate|
      candidate.to_table == "hitch_clients"
    end
    assert_equal "cascade", foreign_key&.options&.fetch(:on_delete, nil).to_s
  end

  def redirect_state_version(database)
    database.connection.select_value(<<~SQL.squish).to_i
      SELECT version FROM hitch_schema_states WHERE key = 'redirect_uris'
    SQL
  end

  def redirect_rows(database, client_id)
    quoted_id = database.connection.quote(client_id)
    database.connection.select_values(<<~SQL.squish)
      SELECT uri
      FROM hitch_client_redirect_uris
      WHERE hitch_client_id = #{quoted_id}
      ORDER BY uri
    SQL
  end
end
