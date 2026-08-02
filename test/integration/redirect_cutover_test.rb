# frozen_string_literal: true

require "test_helper"
require "rake"
require_relative "../support/redirect_storage_database"

class RedirectCutoverTest < ActiveSupport::TestCase
  include RedirectStorageDatabase

  self.use_transactional_tests = false

  setup do
    unless Rake::Task.task_defined?("hitch:redirects:cutover")
      Rake.application.rake_require("tasks/hitch", [ File.expand_path("../../lib", __dir__) ])
      Rake::Task.define_task(:environment)
    end
  end

  teardown do
    %w[hitch:redirects:cutover hitch:redirects:prepare_rollback].each do |name|
      Rake::Task[name].reenable if Rake::Task.task_defined?(name)
    end
  end

  test "authority round trip preserves old-writer and dual-writer additions and deletions" do
    with_redirect_storage_database do |database|
      if database.sqlite?
        assert_fresh_sqlite_transition_posture(database)
        next
      end

      create_legacy_clients_table(database)
      legacy_client = Class.new(database.base) do
        self.table_name = "hitch_clients"
      end
      record = legacy_client.create!(
        client_id: "round-trip-client",
        client_name: "Round Trip",
        redirect_uris: [ "https://before.example/callback" ]
      )
      migrate_redirect_storage(database, NormalizeHitchClientRedirectUris, :up)

      with_hitch_models_on(database) do
        client = Hitch::Client.find(record.id)
        assert_equal 1, Hitch::SchemaState.redirect_uris_version

        output, warnings, status = invoke_redirect_task("hitch:redirects:cutover")
        assert_nil status
        assert_match(/version 2/, output)
        assert_match(/Drain every redirect-mutating old writer/, warnings)
        assert_equal 2, Hitch::SchemaState.redirect_uris_version

        output, warnings, status = invoke_redirect_task("hitch:redirects:prepare_rollback")
        assert_nil status
        assert_match(/version 1/, output)
        assert_match(/Do not return old writers/, warnings)
        assert_equal 1, Hitch::SchemaState.redirect_uris_version

        # An old process replaces the legacy array: the original URI is
        # deleted and a new one is added while version 1 is authoritative.
        client.update_column(
          :redirect_uris,
          [ "https://old-writer.example/callback", "https://keep.example/callback" ]
        )
        assert_equal(
          [ "https://old-writer.example/callback", "https://keep.example/callback" ],
          client.reload.redirect_uris
        )

        # New code in compatibility mode replaces both representations,
        # deleting the old-writer-only URI and adding a dual-written URI.
        client.redirect_uris = [
          "https://keep.example/callback",
          "https://dual-writer.example/callback"
        ]
        assert_equal(
          [ "https://keep.example/callback", "https://dual-writer.example/callback" ],
          client.reload[:redirect_uris]
        )
        assert_equal(
          [ "https://dual-writer.example/callback", "https://keep.example/callback" ],
          client.redirect_uri_records.order(:uri).pluck(:uri)
        )

        _output, _warnings, status = invoke_redirect_task("hitch:redirects:cutover")
        assert_nil status
        assert_equal 2, Hitch::SchemaState.redirect_uris_version
        assert_equal(
          [ "https://dual-writer.example/callback", "https://keep.example/callback" ],
          client.reload.redirect_uris
        )

        # Repeating an already-completed cutover is a successful no-op.
        output, _warnings, status = invoke_redirect_task("hitch:redirects:cutover")
        assert_nil status
        assert_match(/version 2/, output)
      end
    end
  end

  test "rollback preparation refuses divergence and leaves version 2 authoritative" do
    with_redirect_storage_database do |database|
      if database.sqlite?
        migrate_redirect_storage(database, CreateHitchTables, :up)
        with_hitch_models_on(database) do
          _output, errors, status = invoke_redirect_task("hitch:redirects:prepare_rollback")
          assert_equal 1, status
          assert_match(/legacy redirect_uris column is unavailable/, errors)
          assert_equal 2, Hitch::SchemaState.redirect_uris_version
        end
        next
      end

      create_legacy_clients_table(database)
      legacy_client = Class.new(database.base) do
        self.table_name = "hitch_clients"
      end
      record = legacy_client.create!(
        client_id: "divergent-client",
        client_name: "Divergent",
        redirect_uris: [ "https://client.example/callback" ]
      )
      migrate_redirect_storage(database, NormalizeHitchClientRedirectUris, :up)

      with_hitch_models_on(database) do
        _output, _warnings, status = invoke_redirect_task("hitch:redirects:cutover")
        assert_nil status

        Hitch::Client.find(record.id).redirect_uri_records.delete_all
        _output, errors, status = invoke_redirect_task("hitch:redirects:prepare_rollback")

        assert_equal 1, status
        assert_match(/representations disagree/, errors)
        assert_match(/without changing authority/, errors)
        assert_equal 2, Hitch::SchemaState.redirect_uris_version
      end
    end
  end

  test "cutover preserves a legacy redirect set larger than the new-write limit" do
    with_redirect_storage_database do |database|
      if database.sqlite?
        migrate_redirect_storage(database, CreateHitchTables, :up)
        refute database.connection.column_exists?(:hitch_clients, :redirect_uris)
        version = database.connection.select_value(
          "SELECT version FROM hitch_schema_states WHERE key = 'redirect_uris'"
        )
        assert_equal 2, version.to_i
        next
      end

      create_legacy_clients_table(database)
      redirects = (Hitch::Client::MAX_REDIRECT_URIS + 1).times.map do |index|
        "https://legacy-#{index}.test/callback"
      end
      legacy_client = Class.new(database.base) do
        self.table_name = "hitch_clients"
      end
      record = legacy_client.create!(
        client_id: "oversized-legacy",
        client_name: "Legacy",
        redirect_uris: redirects
      )
      migrate_redirect_storage(database, NormalizeHitchClientRedirectUris, :up)

      with_hitch_models_on(database) do
        client = Hitch::Client.find(record.id)
        assert_equal 1, Hitch::SchemaState.redirect_uris_version

        _output, _warnings, status = invoke_redirect_task("hitch:redirects:cutover")

        assert_nil status
        assert_equal 2, Hitch::SchemaState.redirect_uris_version
        assert_equal redirects.sort, client.reload.redirect_uris
      end
    end
  end

  private

  def assert_fresh_sqlite_transition_posture(database)
    migrate_redirect_storage(database, CreateHitchTables, :up)
    now = database.connection.quote(Time.current)
    database.connection.execute <<~SQL.squish
      INSERT INTO hitch_clients (client_id, client_name, created_at, updated_at)
      VALUES ('fresh-sqlite-client', 'Fresh SQLite', #{now}, #{now})
    SQL
    client_id = database.connection.select_value(<<~SQL.squish)
      SELECT id FROM hitch_clients WHERE client_id = 'fresh-sqlite-client'
    SQL
    database.connection.execute <<~SQL.squish
      INSERT INTO hitch_client_redirect_uris (hitch_client_id, uri, created_at, updated_at)
      VALUES (#{database.connection.quote(client_id)}, 'https://client.example/callback', #{now}, #{now})
    SQL

    with_hitch_models_on(database) do
      client = Hitch::Client.find(client_id)

      output, warnings, status = invoke_redirect_task("hitch:redirects:cutover")
      assert_nil status
      assert_match(/version 2/, output)
      assert_match(/Drain every redirect-mutating old writer/, warnings)
      assert_equal [ "https://client.example/callback" ], client.redirect_uris

      _output, errors, status = invoke_redirect_task("hitch:redirects:prepare_rollback")
      assert_equal 1, status
      assert_match(/legacy redirect_uris column is unavailable/, errors)
      assert_equal 2, Hitch::SchemaState.redirect_uris_version
    end
  end

  def invoke_redirect_task(name)
    output = StringIO.new
    errors = StringIO.new
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = output
    $stderr = errors

    status = nil
    begin
      task = Rake::Task[name]
      task.reenable
      task.invoke
    rescue SystemExit => error
      status = error.status
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end

    [ output.string, errors.string, status ]
  end
end
