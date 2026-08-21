# frozen_string_literal: true

require "digest"

module AccessTokenExchange
  def exchange_authorization_code(record, verifier:, raw_code: record.raw_authorization_code,
    client_id: record.client_id, resource_uri: record.resource_uri)
    result = Hitch::AccessToken.exchange_authorization_code!(
      raw_code: raw_code,
      code_verifier: verifier,
      client_id: client_id,
      resource_uri: resource_uri
    )
    record.reload if result
    result&.fetch(:raw_token)
  end

  def authorization_code_pending?(raw_code)
    return false if raw_code.blank?

    digest = Digest::SHA256.hexdigest(raw_code)
    Hitch::AccessToken.pending.exists?(authorization_code_digest: digest)
  end
end
