# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "pathname"
require "securerandom"

authorization_path = Pathname(ENV.fetch("HITCH_CONFORMANCE_SERVER_AUTHORIZATION_FILE"))
resource = ENV.fetch("HITCH_CONFORMANCE_RESOURCE_URI")

Hitch::AccessToken.delete_all
Hitch::ClientRedirectUri.delete_all
Hitch::Client.delete_all
User.delete_all

user = User.create!(email: "hitch-server-conformance@example.test")
client = Hitch::Client.register!(
  client_id: "hitch-server-conformance",
  client_name: "Hitch server conformance fixture",
  redirect_uris: [ "https://conformance.example.test/callback" ]
)
verifier = SecureRandom.urlsafe_base64(64)
challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
authorization = Hitch::AccessToken.create_authorization!(
  principal: user,
  client_id: client.client_id,
  client_name: client.client_name,
  code_challenge: challenge,
  code_challenge_method: "S256",
  resource_uri: resource
)
exchange = Hitch::AccessToken.exchange_authorization_code!(
  raw_code: authorization.raw_authorization_code,
  code_verifier: verifier,
  client_id: client.client_id,
  resource_uri: resource
)
abort "Conformance fixture token exchange failed" unless exchange

raw_token = exchange.fetch(:raw_token)
File.open(authorization_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
  file.write("Bearer #{raw_token}")
end

puts JSON.generate(
  client_id: client.client_id,
  token_sha256: Digest::SHA256.hexdigest(raw_token),
  authorization_file_mode: "0600"
)
