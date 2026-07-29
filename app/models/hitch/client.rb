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

    # OpenID Connect Dynamic Client Registration 1.0 §2 defines exactly
    # these two. (Not RFC 7591 — that spec has no application_type; the
    # field is IANA-registered, which is how it rides along in an
    # otherwise RFC 7591 registration request.) A client sending anything
    # else is recorded as having declared nothing, rather than having its
    # registration rejected — see #normalize_application_type.
    APPLICATION_TYPES = %w[native web].freeze

    validates :client_id, presence: true, uniqueness: true
    validates :application_type, inclusion: { in: APPLICATION_TYPES }, allow_nil: true

    def self.register!(client_id:, client_name:, redirect_uris:, application_type: nil)
      create!(
        client_id: client_id,
        client_name: client_name.presence || "MCP Client",
        redirect_uris: Array.wrap(redirect_uris).select { |v| v.is_a?(String) }.compact_blank,
        application_type: normalize_application_type(application_type)
      )
    end

    # Unrecognized values become nil rather than a registration error.
    # `application_type` is recorded, never enforced (see the migration),
    # so a junk value costs nothing to drop — whereas rejecting the
    # registration would break a client over a field the server does not
    # yet act on. Absent and unrecognized are both "did not declare",
    # which is the honest reading of each.
    def self.normalize_application_type(value)
      value = value.to_s
      APPLICATION_TYPES.include?(value) ? value : nil
    end
  end
end
