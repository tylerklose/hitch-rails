# ADR 0002: Configuration is the sole registry authority

## Status

Accepted for registry authority; lifecycle amended after 0.4.

## Context

The independently converged evidence supports an explicit allowlist and per-
principal filtering, but Rails reloadable constants cannot safely live in a
long-lived configuration object. A second controller-level registry setting
would create competing authorities. Partial reload validation can serve stale
or half-valid tools. `Rails::Application::Finisher` runs
`:run_prepare_callbacks` before `:eager_load!`; resolving the registry from the
initial `to_prepare` callback therefore loads host tools before Rails reaches
its own eager-load phase. The same finisher runs `:eager_load!` before
`:finisher_hook`, which invokes `after_initialize`. Rails main guards load hooks
while both `eager_load` and `initialized?` are false. Rake's environment task
replaces `eager_load` with the normally-false `rake_eager_load`, which is why a
production Doctor task reaches that guard while a normal eager server does not.

## Decision

`config.mcp.registry` stores one String constant name. A
`Hitch::MCP::Registry` subclass is ordinary application code; `register` stores
tool class names and frozen static scopes only.

Hitch prepares one immutable snapshot from `after_initialize` when the
application eager-loads. Rails invokes that hook after `:eager_load!`, although
before `initialize!` flips the application's `initialized?` flag. Non-eager
applications instead prepare on the first MCP dispatch. `hitch:doctor` skips
automatic preparation and explicitly prepares while collecting registry facts,
after the task application has booted.

`Rails.application.reloader.before_class_unload` clears the snapshot before
Rails unloads reloadable classes. Eager applications rebuild from
`after_class_unload`, after Rails has eager-loaded its main autoloader again.
Active Support executes after callbacks in reverse registration order, so Hitch
prepends its callback to leave Rails' earlier callback first. Snapshot
resolution, validation, and publication hold one mutex; a concurrent clear
waits and then wins, and a failed rebuild leaves no prior snapshot available.

Validation rejects anonymous/missing/non-Tool classes, duplicate or invalid
names, missing descriptions/schemas/scopes, unsupported scopes/schema/annotations,
explicit effective top-level `server_context`, and subclass overrides of
framework-owned `.call`. Listing is MCP-name ascending. Each request resolves
the current snapshot, evaluates deny-default availability, then static scopes,
and constructs the SDK from only that filtered set.

## Consequences

Registry changes follow Rails reload behavior without sharing principal state.
An invalid eager boot or eager reload, or the next MCP dispatch after an invalid
non-eager reload, is deliberately loud and unavailable rather than silently
falling back. A non-eager process that never uses MCP does not load or validate
the registry merely because the application booted. Automatic discovery and a
controller registry are not supported.

## Removal and verification

Reload tests retain old class objects only as canaries and prove they are never
served. Real host boots cover non-eager first use and both Rails class-unload
modes; production task tests cover Doctor. Mutations that store constants,
publish after a concurrent invalidation, retain the old snapshot after failed
validation, commit entries incrementally, rescue a failed reload, or filter
only the response must fail.
