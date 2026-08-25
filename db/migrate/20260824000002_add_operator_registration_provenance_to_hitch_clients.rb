# frozen_string_literal: true

class AddOperatorRegistrationProvenanceToHitchClients < ActiveRecord::Migration[7.2]
  def up
    # 0.3 stored the token authentication method but not who created the
    # registration, so an existing confidential row might have come from the
    # anonymous DCR endpoint. False is the only honest, fail-closed backfill;
    # the operator can vouch for one by rotating its secret and restating its
    # display name through hitch:clients:rotate_secret.
    add_column :hitch_clients, :operator_registered,
      :boolean, null: false, default: false
    add_check_constraint :hitch_clients,
      "operator_registered = FALSE OR token_endpoint_auth_method = 'client_secret_basic'",
      name: "hitch_clients_operator_registration_check"
  end

  def down
    remove_check_constraint :hitch_clients, name: "hitch_clients_operator_registration_check"
    remove_column :hitch_clients, :operator_registered
  end
end
