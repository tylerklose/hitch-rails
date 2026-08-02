# frozen_string_literal: true

class AddConfidentialCredentialsToHitchClients < ActiveRecord::Migration[7.1]
  AUTH_METHOD_CHECK = "hitch_clients_auth_method_check"
  SECRET_CHECK = "hitch_clients_secret_consistency_check"

  def up
    add_column :hitch_clients,
      :token_endpoint_auth_method,
      :string,
      null: false,
      default: "none" unless column_exists?(:hitch_clients, :token_endpoint_auth_method)
    add_column :hitch_clients, :client_secret_digest, :string unless column_exists?(:hitch_clients, :client_secret_digest)
    add_column :hitch_clients, :client_secret_issued_at, :datetime unless column_exists?(:hitch_clients, :client_secret_issued_at)
    add_column :hitch_clients, :client_secret_rotated_at, :datetime unless column_exists?(:hitch_clients, :client_secret_rotated_at)

    add_check_constraint :hitch_clients,
      "token_endpoint_auth_method IN ('none', 'client_secret_basic')",
      name: AUTH_METHOD_CHECK,
      if_not_exists: true
    secret_constraint = <<~SQL.squish
      (token_endpoint_auth_method = 'none' AND client_secret_digest IS NULL AND client_secret_issued_at IS NULL AND client_secret_rotated_at IS NULL)
      OR
      (token_endpoint_auth_method = 'client_secret_basic' AND client_secret_digest IS NOT NULL AND client_secret_issued_at IS NOT NULL)
    SQL
    add_check_constraint :hitch_clients,
      secret_constraint,
      name: SECRET_CHECK,
      if_not_exists: true
  end

  def down
    remove_check_constraint :hitch_clients, name: SECRET_CHECK, if_exists: true
    remove_check_constraint :hitch_clients, name: AUTH_METHOD_CHECK, if_exists: true
    remove_column :hitch_clients, :client_secret_rotated_at if column_exists?(:hitch_clients, :client_secret_rotated_at)
    remove_column :hitch_clients, :client_secret_issued_at if column_exists?(:hitch_clients, :client_secret_issued_at)
    remove_column :hitch_clients, :client_secret_digest if column_exists?(:hitch_clients, :client_secret_digest)
    remove_column :hitch_clients, :token_endpoint_auth_method if column_exists?(:hitch_clients, :token_endpoint_auth_method)
  end
end
