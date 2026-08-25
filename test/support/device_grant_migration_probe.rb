# frozen_string_literal: true

# Runs inside bin/ci-migrations against the same disposable database before
# and after 20260824000001. Raw SQL is intentional: the current model expects
# a column that does not exist yet in the pre-upgrade schema.

connection = ActiveRecord::Base.connection

insert_row = lambda do |table, attributes|
  columns = attributes.keys.map { |name| connection.quote_column_name(name) }.join(", ")
  values = attributes.values.map { |value| connection.quote(value) }.join(", ")
  connection.execute("INSERT INTO #{connection.quote_table_name(table)} (#{columns}) VALUES (#{values})")
end

case ENV.fetch("HITCH_MIGRATION_PROBE")
when "seed"
  abort "posture column already exists before upgrade" if
    connection.column_exists?(:hitch_device_grants, :token_endpoint_auth_method)

  now = Time.current
  insert_row.call("hitch_clients", {
    client_id: "legacy-confidential-client",
    client_name: "Legacy confidential client",
    application_type: "web",
    token_endpoint_auth_method: "client_secret_basic",
    client_secret_digest: "legacy-secret-digest",
    client_secret_issued_at: now,
    created_at: now,
    updated_at: now
  })
  insert_row.call("hitch_device_grants", {
    client_id: "legacy-confidential-client",
    device_code_digest: "legacy-device-digest",
    user_code_digest: "legacy-user-digest",
    scopes: "mcp",
    resource_uri: "https://migration.example/mcp",
    expires_at: 10.minutes.from_now,
    created_at: now,
    updated_at: now
  })
  # Not expected in a real host, but cheap to prove: malformed prerelease
  # rows cannot block the fail-closed purge from installing constraints.
  insert_row.call("hitch_device_grants", {
    client_id: "ownerless-prerelease-client",
    device_code_digest: "ownerless-device-digest",
    scopes: "mcp",
    resource_uri: "https://migration.example/mcp",
    expires_at: 10.minutes.from_now,
    approved_at: now,
    created_at: now,
    updated_at: now
  })
  abort "migration probe did not seed two device grants" unless
    connection.select_value("SELECT COUNT(*) FROM hitch_device_grants").to_i == 2

  puts "device_grant_migration_probe seed=ok"
when "verify"
  column = connection.columns(:hitch_device_grants).find do |candidate|
    candidate.name == "token_endpoint_auth_method"
  end
  abort "posture column is missing after upgrade" unless column
  abort "posture column must be non-null" unless column.null == false
  abort "posture column must not have a public-client default" unless column.default.nil?
  abort "pre-upgrade device grants survived the fail-closed migration" unless
    connection.select_value("SELECT COUNT(*) FROM hitch_device_grants").to_i.zero?
  abort "migration deleted a client registration" unless
    connection.select_value(<<~SQL.squish).to_i == 1
      SELECT COUNT(*) FROM hitch_clients WHERE client_id = 'legacy-confidential-client'
    SQL
  operator_column = connection.columns(:hitch_clients).find do |candidate|
    candidate.name == "operator_registered"
  end
  abort "operator provenance column is missing after upgrade" unless operator_column
  abort "operator provenance column must be non-null" unless operator_column.null == false
  abort "operator provenance column must fail closed by default" unless
    ActiveModel::Type::Boolean.new.cast(operator_column.default) == false
  abort "an unclassified legacy client was treated as operator-registered" unless
    connection.select_value(<<~SQL.squish).to_i.zero?
      SELECT COUNT(*) FROM hitch_clients
      WHERE client_id = 'legacy-confidential-client' AND operator_registered = TRUE
    SQL

  required_constraints = %w[
    hitch_device_grants_auth_method_check
    hitch_device_grants_consumption_check
    hitch_device_grants_decision_check
    hitch_device_grants_principal_check
  ]
  actual_constraints = connection.check_constraints(:hitch_device_grants).map(&:name)
  missing_constraints = required_constraints - actual_constraints
  abort "missing device-grant constraints: #{missing_constraints.join(', ')}" if missing_constraints.any?

  client_constraints = connection.check_constraints(:hitch_clients).map(&:name)
  abort "missing client provenance constraint" unless
    client_constraints.include?("hitch_clients_operator_registration_check")

  puts "device_grant_migration_probe verify=ok"
else
  abort "HITCH_MIGRATION_PROBE must be seed or verify"
end
