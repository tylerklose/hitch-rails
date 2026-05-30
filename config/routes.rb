# frozen_string_literal: true

Hitch::Engine.routes.draw do
  # OAuth dance
  get  "oauth/authorize", to: "authorizations#new",   as: :oauth_authorize
  post "oauth/authorize", to: "authorizations#create"
  post "oauth/token",     to: "tokens#create",        as: :oauth_token
  post "oauth/register",  to: "registrations#create", as: :oauth_register
  post "oauth/revoke",    to: "revocations#create",   as: :oauth_revoke

  # CORS preflight for any /oauth/* endpoint
  match "oauth/*path", to: "tokens#preflight", via: :options

  # Discovery (RFC 8414 + RFC 9728)
  get ".well-known/oauth-authorization-server", to: "metadata#show",     as: :oauth_authorization_server_metadata
  get ".well-known/oauth-protected-resource",   to: "metadata#resource", as: :oauth_protected_resource_metadata

  # RFC 9728 §3.1: a resource served at a path (e.g. /mcp) publishes its
  # metadata at the PATH-AWARE well-known URI. Strict clients (Grok)
  # request /.well-known/oauth-protected-resource/<path> FIRST, then fall
  # back to the bare variant — without this route that first probe 404s.
  # The gem serves a single configured resource, so the captured path is
  # ignored and the same document is returned. `format: false` keeps a
  # dotted resource path from being parsed as a response format. Declared
  # after the bare route (glob-last).
  get ".well-known/oauth-protected-resource/*resource_path", to: "metadata#resource", format: false

  # CORS preflight for discovery — browser MCP clients (claude.ai,
  # chatgpt.com) preflight discovery before issuing the GET.
  match ".well-known/oauth-authorization-server", to: "tokens#preflight", via: :options
  match ".well-known/oauth-protected-resource",   to: "tokens#preflight", via: :options
  match ".well-known/oauth-protected-resource/*resource_path", to: "tokens#preflight", via: :options, format: false
end
