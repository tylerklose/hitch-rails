# ADR 0002: Configuration is the sole registry authority

## Status

Accepted for the 0.2 contract.

## Context

The independently converged evidence supports an explicit allowlist and per-
principal filtering, but Rails reloadable constants cannot safely live in a
long-lived configuration object. A second controller-level registry setting
would create competing authorities. Partial reload validation can serve stale
or half-valid tools.

## Decision

`config.mcp.registry` stores one String constant name. A
`Hitch::MCP::Registry` subclass is ordinary application code; `register` stores
tool class names and frozen static scopes only. The entire registry is
constantized/validated into a new immutable snapshot under
`Rails.application.config.to_prepare`. Validation failure rejects the whole
snapshot: production boot fails and development reload raises while serving no
stale reloadable classes.

Validation rejects anonymous/missing/non-Tool classes, duplicate or invalid
names, missing descriptions/schemas/scopes, unsupported scopes/schema/annotations,
explicit effective top-level `server_context`, and subclass overrides of
framework-owned `.call`. Listing is MCP-name ascending. Each request resolves
the current snapshot, evaluates deny-default availability, then static scopes,
and constructs the SDK from only that filtered set.

## Consequences

Registry changes follow Rails reload behavior without sharing principal state.
An invalid reload is deliberately loud and unavailable rather than silently
falling back. Automatic discovery and a controller registry are not supported.

## Removal and verification

Reload tests retain old class objects only as canaries and prove they are never
served. Mutations that store constants, commit entries incrementally, rescue a
failed reload, or filter only the response must fail.
