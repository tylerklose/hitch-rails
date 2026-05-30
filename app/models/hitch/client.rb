# frozen_string_literal: true

module Hitch
  # OAuth Dynamic Client Registration (RFC 7591) record. Captures the
  # human-readable client_name an MCP client sends during DCR so the
  # authorize flow can attribute records back to the originating
  # application (Claude Code, ChatGPT, Cursor, etc.).
  #
  # The client_name is attacker-controllable (anyone can POST to
  # /oauth/register with any client_name); consent UIs should NOT
  # trust it for display. Storage keeps it for audit fidelity.
  class Client < ApplicationRecord
    self.table_name = "hitch_clients"

    validates :client_id, presence: true, uniqueness: true

    def self.register!(client_id:, client_name:, redirect_uris:)
      create!(
        client_id: client_id,
        client_name: client_name.presence || "MCP Client",
        redirect_uris: Array.wrap(redirect_uris).select { |v| v.is_a?(String) }.compact_blank
      )
    end
  end
end
