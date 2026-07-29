# frozen_string_literal: true

# MCP 2026-07-28 has clients declare `application_type` during Dynamic
# Client Registration, specifically so an authorization server can tell a
# native/CLI client (which needs a loopback redirect on an ephemeral
# port) from a web one.
#
# Nullable, and deliberately NOT defaulted to "web". OpenID Connect
# Dynamic Client Registration 1.0 §2 — which defines the field; RFC 7591
# does not — says it defaults to "web" when omitted, but adopting that
# default here
# would erase the distinction that makes the column useful: a client that
# genuinely declared "web" and a client from before the field existed
# would be indistinguishable. Claude Code omits it today and depends on
# loopback redirects, so a future decision to gate loopback on
# `application_type == "native"` must be able to see who actually said
# so. NULL means "did not declare", which is the fact worth recording.
class AddApplicationTypeToHitchClients < ActiveRecord::Migration[7.1]
  def change
    add_column :hitch_clients, :application_type, :string
  end
end
