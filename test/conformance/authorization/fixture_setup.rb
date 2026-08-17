# frozen_string_literal: true

require "json"
require "pathname"
require "securerandom"

fixture_directory = Pathname(ENV.fetch("HITCH_CONFORMANCE_FIXTURE_DIR"))
issuer = ENV.fetch("HITCH_CONFORMANCE_ISSUER")
resource = ENV.fetch("HITCH_CONFORMANCE_RESOURCE_URI")
callback_port = Integer(ENV.fetch("HITCH_CONFORMANCE_CALLBACK_PORT"), 10)
callback_uri = "http://127.0.0.1:#{callback_port}/callback"

abort "Fixture directory must already exist" unless fixture_directory.directory?

User.delete_all
Hitch::AccessToken.delete_all
Hitch::Client.delete_all

user = User.create!(email: "hitch-conformance@example.test")
public_client = Hitch::Client.register!(
  client_id: SecureRandom.uuid,
  client_name: "Hitch public conformance fixture",
  redirect_uris: [ callback_uri ]
)
confidential = Hitch::Client.register_confidential!(
  client_id: SecureRandom.uuid,
  client_name: "Hitch confidential conformance fixture",
  redirect_uris: [ callback_uri ]
)

def write_private_json(path, value)
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(JSON.generate(value))
  end
end

common = { url: issuer, resource: resource, port: callback_port }
write_private_json(
  fixture_directory.join("public-settings.json"),
  common.merge(clientId: public_client.client_id)
)
write_private_json(
  fixture_directory.join("confidential-settings.json"),
  common.merge(
    clientId: confidential.client.client_id,
    clientSecret: confidential.client_secret
  )
)

puts JSON.generate(
  user_id: user.id,
  public_client_id: public_client.client_id,
  confidential_client_id: confidential.client.client_id,
  callback_uri: callback_uri
)
