# ADR 0003: Two host gates and one closed result channel

## Status

Accepted for the 0.2 contract.

## Context

Independent roots support coarse per-principal filtering. The copied lineage
also demonstrates a useful split between coarse scope and argument-aware host
policy, but does not justify its implementation or a general policy adapter.
SDK probes show detailed unknown/schema/host errors can disclose internals.

## Decision

`.available_to?(context)` is coarse, argument-free, deny-default, and runs for
list and call. Registered/available tools then require their static OAuth scopes.
Only after SDK input validation does `.authorize!(context, arguments:)` receive
one recursively frozen string-keyed Hash; it defaults to raising
`Hitch::MCP::Forbidden`. `.perform` runs only after policy allows. Framework
`.call(server_context:, **sdk_arguments)` is final.

Unknown/unregistered/unavailable share SDK `-32602`; a known available tool
without static scope gets 403; policy denial gets a generic tool error with zero
host calls. Host execution must return `Hitch::MCP::Result.text`, `.structured`,
or `.error`. Only `.error` preserves its explicit host-approved message.
Structured success requires an output schema and passes Hitch schema/JSON byte-
cap validation before SDK validation. Every unexpected/invalid/oversize result
or exception is generic externally and sanitized through `Rails.error`.

## Consequences

Pundit, Action Policy, model predicates, record scopes, transactions, and
idempotency stay ordinary host code. Hitch does not grow a policy-adapter
registry, implicit serializer, persistent audit table, or exception taxonomy.

## Removal and verification

The exhaustive Lattice precedence and forced reserved-key/schema/result/error
suites kill mutations that reorder or bypass gates, execute after denial,
accept arbitrary results, relax caps, or reveal messages.
