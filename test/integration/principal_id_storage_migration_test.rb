# frozen_string_literal: true

require "base64"
require "digest"
require "securerandom"
require "test_helper"
require_relative "../support/redirect_storage_database"

class PrincipalIdIntegerPrincipal < RedirectStorageDatabaseRecord
  self.table_name = "principal_id_integer_principals"
end

class PrincipalIdStringPrincipal < RedirectStorageDatabaseRecord
  self.table_name = "principal_id_string_principals"
end

class PrincipalIdStorageMigrationTest < ActiveSupport::TestCase
  include RedirectStorageDatabase

  RESOURCE_URI = "https://resource.example/mcp"

  self.use_transactional_tests = false

  test "fresh installs preserve integer and UUID principals through token exchange" do
    with_redirect_storage_database do |database|
      migrate_redirect_storage(database, CreateHitchTables, :up)
      migrate_redirect_storage(database, HashAuthorizationCodes, :up)
      migrate_redirect_storage(database, StringifyHitchAccessTokenPrincipalIds, :up)
      create_principal_tables(database)

      assert_principal_id_string(database)
      assert_principal_index(database)

      with_hitch_models_on(database) do
        integer_principal = PrincipalIdIntegerPrincipal.create!
        uuid_principal = PrincipalIdStringPrincipal.create!(id: SecureRandom.uuid)

        [ integer_principal, uuid_principal ].each do |principal|
          token = issue_and_exchange(principal)

          assert_equal principal.id.to_s, token.principal_id
          assert_equal principal, token.principal
        end
      end
    end
  end

  test "upgrade widens numeric principal IDs losslessly and remains retryable" do
    with_redirect_storage_database do |database|
      create_legacy_access_tokens_table(database)
      create_principal_tables(database)
      principal = PrincipalIdIntegerPrincipal.create!(id: 42)
      token_id = insert_legacy_token(database, principal)

      migrate_redirect_storage(database, StringifyHitchAccessTokenPrincipalIds, :up)

      assert_principal_id_string(database)
      assert_equal "42", stored_principal_id(database, token_id)
      assert_principal_index(database)
      with_hitch_models_on(database) do
        token = Hitch::AccessToken.find(token_id)

        assert_equal "42", token.principal_id
        assert_equal principal, token.principal
      end

      migrate_redirect_storage(database, StringifyHitchAccessTokenPrincipalIds, :up)
      migrate_redirect_storage(database, StringifyHitchAccessTokenPrincipalIds, :down)

      assert_principal_id_numeric(database)
      assert_equal 42, stored_principal_id(database, token_id).to_i
      assert_principal_index(database)

      migrate_redirect_storage(database, StringifyHitchAccessTokenPrincipalIds, :up)
      assert_principal_id_string(database)
      assert_equal "42", stored_principal_id(database, token_id)
    end
  end

  test "rollback refuses to corrupt UUID principal authority" do
    with_redirect_storage_database do |database|
      create_legacy_access_tokens_table(database)
      create_principal_tables(database)
      migrate_redirect_storage(database, StringifyHitchAccessTokenPrincipalIds, :up)

      uuid_principal = PrincipalIdStringPrincipal.create!(id: SecureRandom.uuid)
      token = nil
      with_hitch_models_on(database) do
        token = issue_and_exchange(uuid_principal)
      end

      error = assert_raises(ActiveRecord::IrreversibleMigration) do
        migrate_redirect_storage(database, StringifyHitchAccessTokenPrincipalIds, :down)
      end

      assert_match(/corrupt principal authority/, error.message)
      assert_principal_id_string(database)
      assert_equal uuid_principal.id, stored_principal_id(database, token.id)
      assert_principal_index(database)
    end
  end

  private

  def create_principal_tables(database)
    database.connection.create_table :principal_id_integer_principals
    database.connection.create_table :principal_id_string_principals, id: :string
    PrincipalIdIntegerPrincipal.reset_column_information
    PrincipalIdStringPrincipal.reset_column_information
  end

  def create_legacy_access_tokens_table(database)
    database.connection.create_table :hitch_access_tokens do |table|
      table.references :principal, polymorphic: true, null: false, index: true
      table.string :client_id, null: false
      table.string :client_name
      table.string :authorization_code_digest,
        index: { unique: true, where: "authorization_code_digest IS NOT NULL" }
      table.datetime :code_expires_at
      table.string :redirect_uri
      table.string :code_challenge, null: false
      table.string :code_challenge_method, null: false, default: "S256"
      table.string :token_digest,
        index: { unique: true, where: "token_digest IS NOT NULL" }
      table.datetime :expires_at
      table.datetime :revoked_at
      table.string :resource_uri
      table.string :scopes, null: false, default: "mcp"
      table.timestamps
    end
  end

  def insert_legacy_token(database, principal)
    legacy_token = Class.new(database.base) do
      self.table_name = "hitch_access_tokens"
    end
    record = legacy_token.create!(
      principal_type: principal.class.polymorphic_name,
      principal_id: principal.id,
      client_id: "legacy-client",
      code_challenge: pkce_challenge("legacy-verifier"),
      code_challenge_method: "S256"
    )
    record.id
  end

  def issue_and_exchange(principal)
    verifier = SecureRandom.urlsafe_base64(64)
    authorization = Hitch::AccessToken.create_authorization!(
      principal: principal,
      client_id: "client-#{SecureRandom.hex(8)}",
      client_name: "Migration test client",
      code_challenge: pkce_challenge(verifier),
      code_challenge_method: "S256",
      resource_uri: RESOURCE_URI
    )
    result = Hitch::AccessToken.exchange_authorization_code!(
      raw_code: authorization.raw_authorization_code,
      code_verifier: verifier,
      client_id: authorization.client_id,
      resource_uri: RESOURCE_URI
    )

    assert result, "authorization code should exchange exactly once"
    Hitch::AccessToken.find_by_token(result.fetch(:raw_token))
  end

  def pkce_challenge(verifier)
    Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
  end

  def stored_principal_id(database, token_id)
    quoted_id = database.connection.quote(token_id)
    database.connection.select_value(<<~SQL.squish)
      SELECT principal_id FROM hitch_access_tokens WHERE id = #{quoted_id}
    SQL
  end

  def assert_principal_id_string(database)
    assert_equal :string, principal_id_column(database).type
  end

  def assert_principal_id_numeric(database)
    assert_equal :integer, principal_id_column(database).type
  end

  def principal_id_column(database)
    database.connection.columns(:hitch_access_tokens).find do |column|
      column.name == "principal_id"
    end
  end

  def assert_principal_index(database)
    index = database.connection.indexes(:hitch_access_tokens).find do |candidate|
      candidate.columns == %w[principal_type principal_id]
    end

    assert index, "principal type/ID index must survive the migration"
  end
end
