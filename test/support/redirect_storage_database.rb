# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "tmpdir"

require File.expand_path("../../db/migrate/20260528020918_create_hitch_tables", __dir__)
require File.expand_path("../../db/migrate/20260528041652_hash_authorization_codes", __dir__)
require File.expand_path("../../db/migrate/20260729183000_add_application_type_to_hitch_clients", __dir__)
require File.expand_path("../../db/migrate/20260801090000_normalize_hitch_client_redirect_uris", __dir__)
require File.expand_path("../../db/migrate/20260801090500_cascade_hitch_client_redirect_deletes", __dir__)
require File.expand_path("../../db/migrate/20260801091000_add_confidential_credentials_to_hitch_clients", __dir__)
require File.expand_path("../../db/migrate/20260801091500_stringify_hitch_access_token_principal_ids", __dir__)

class RedirectStorageDatabaseRecord < ActiveRecord::Base
  self.abstract_class = true
end

module RedirectStorageDatabase
  Database = Struct.new(:adapter, :config, :base, :temporary_path, :schema, keyword_init: true) do
    def connection
      base.connection
    end

    def postgresql?
      adapter == "postgresql"
    end

    def sqlite?
      adapter == "sqlite3"
    end
  end

  def with_redirect_storage_database
    adapter = ActiveRecord::Base.connection_db_config.adapter

    case adapter
    when "sqlite3"
      with_sqlite_redirect_storage_database { |database| yield database }
    when "postgresql"
      with_postgresql_redirect_storage_database { |database| yield database }
    else
      raise "unsupported redirect migration test adapter: #{adapter}"
    end
  end

  def migrate_redirect_storage(database, migration, direction)
    database.connection.transaction do
      migration.new.exec_migration(database.connection, direction)
    end
  end

  def create_legacy_clients_table(database)
    database.connection.create_table :hitch_clients do |table|
      table.string :client_id, null: false
      table.string :client_name, null: false
      table.string :application_type
      table.string :token_endpoint_auth_method, null: false, default: "none"
      table.string :client_secret_digest
      table.datetime :client_secret_issued_at
      table.datetime :client_secret_rotated_at
      if database.postgresql?
        table.string :redirect_uris, array: true, default: [], null: false
      else
        table.string :redirect_uris, default: "[]", null: false
      end
      table.timestamps
    end
    database.connection.add_index :hitch_clients, :client_id, unique: true
  end

  def with_hitch_models_on(database)
    Hitch::ApplicationRecord.establish_connection(database.config)
    reset_hitch_redirect_model_columns
    yield
  ensure
    if Hitch::ApplicationRecord.connection_specification_name != "ActiveRecord::Base"
      Hitch::ApplicationRecord.connection_pool.disconnect!
      Hitch::ApplicationRecord.remove_connection
    end
    reset_hitch_redirect_model_columns
  end

  private

  def with_sqlite_redirect_storage_database
    directory = Dir.mktmpdir("hitch-redirect-storage-")
    path = File.join(directory, "redirects.sqlite3")
    config = {
      adapter: "sqlite3",
      database: path,
      pool: 5,
      timeout: 5_000
    }
    database = build_redirect_storage_database(
      adapter: "sqlite3",
      config: config,
      temporary_path: directory
    )
    database.connection.execute("PRAGMA foreign_keys = ON")

    yield database
  ensure
    disconnect_redirect_storage_database(database)
    FileUtils.remove_entry(directory) if directory && File.exist?(directory)
  end

  def with_postgresql_redirect_storage_database
    admin = ActiveRecord::Base.connection
    schema = "hitch_redirect_#{Process.pid}_#{SecureRandom.hex(6)}"
    quoted_schema = admin.quote_table_name(schema)
    admin.execute("CREATE SCHEMA #{quoted_schema}")

    config = ActiveRecord::Base.connection_db_config.configuration_hash.merge(
      schema_search_path: schema,
      pool: 5
    )
    database = build_redirect_storage_database(
      adapter: "postgresql",
      config: config,
      schema: schema
    )

    yield database
  ensure
    disconnect_redirect_storage_database(database)
    admin&.execute("DROP SCHEMA IF EXISTS #{quoted_schema} CASCADE") if quoted_schema
  end

  def build_redirect_storage_database(adapter:, config:, temporary_path: nil, schema: nil)
    base = RedirectStorageDatabaseRecord
    base.establish_connection(config)

    Database.new(
      adapter: adapter,
      config: config,
      base: base,
      temporary_path: temporary_path,
      schema: schema
    )
  end

  def disconnect_redirect_storage_database(database)
    return unless database

    database.base.connection_pool.disconnect!
    database.base.remove_connection
  end

  def reset_hitch_redirect_model_columns
    [ Hitch::AccessToken, Hitch::Client, Hitch::ClientRedirectUri ].each(&:reset_column_information)
  end
end
