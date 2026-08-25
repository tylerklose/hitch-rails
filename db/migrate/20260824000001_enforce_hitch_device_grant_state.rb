# frozen_string_literal: true

class EnforceHitchDeviceGrantState < ActiveRecord::Migration[7.2]
  def up
    # These rows are short-lived, unaudited authorization attempts, and the
    # old schema did not record enough information to reconstruct whether the
    # polling client authenticated. Restarting an in-flight flow is the only
    # fail-closed upgrade; issued access tokens live in their own table.
    execute "DELETE FROM hitch_device_grants"

    add_column :hitch_device_grants, :token_endpoint_auth_method,
      :string, null: false

    add_check_constraint :hitch_device_grants,
      "token_endpoint_auth_method IN ('none', 'client_secret_basic')",
      name: "hitch_device_grants_auth_method_check"
    add_check_constraint :hitch_device_grants,
      "NOT (approved_at IS NOT NULL AND denied_at IS NOT NULL)",
      name: "hitch_device_grants_decision_check"
    add_check_constraint :hitch_device_grants, <<~SQL.squish,
      (approved_at IS NULL AND principal_type IS NULL AND principal_id IS NULL)
      OR
      (approved_at IS NOT NULL AND principal_type IS NOT NULL AND principal_id IS NOT NULL)
    SQL
      name: "hitch_device_grants_principal_check"
    add_check_constraint :hitch_device_grants,
      "consumed_at IS NULL OR approved_at IS NOT NULL",
      name: "hitch_device_grants_consumption_check"
  end

  def down
    remove_check_constraint :hitch_device_grants, name: "hitch_device_grants_consumption_check"
    remove_check_constraint :hitch_device_grants, name: "hitch_device_grants_principal_check"
    remove_check_constraint :hitch_device_grants, name: "hitch_device_grants_decision_check"
    remove_check_constraint :hitch_device_grants, name: "hitch_device_grants_auth_method_check"
    remove_column :hitch_device_grants, :token_endpoint_auth_method
  end
end
