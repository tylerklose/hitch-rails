# Removing Hitch from a Rails application

Removal is intentionally non-destructive. Unmounting the engine and removing
the gem must not silently delete OAuth audit data or principal bindings.

1. Disable new authorization and registration traffic at ingress. Set DCR off
   before the final deploy.
2. Revoke active Hitch tokens, or wait for their configured expiry if the MCP
   endpoint has already been disabled.
3. Stop jobs and schedules that call `Hitch::AccessToken.cleanup_expired!` or
   Hitch rake tasks.
4. Back up the `hitch_*` tables and decide their retention period under the
   application's audit and privacy policy.
5. Remove generated tools with
   `bin/rails destroy hitch:tool NAME [--namespace Namespace]` while the gem
   is installed — each removes its files and its registration line, refusing
   the rollback if the registration line was edited — then run
   `bin/rails destroy hitch:install` to remove the initializer, endpoint
   controller, registry, and the `/mcp` route. Review anything you customized
   in your version control history first; destroy reverses what the
   generators wrote.
6. Remove the `mount Hitch::Engine` line — destroy leaves it in place, since
   it cannot tell a generated mount from one that pre-dates the install —
   and any host controller inclusions of `Hitch::ServerEndpoint` or
   `Hitch::CorsSupport`.
7. Remove the Gemfile entry and bundle again.

`hitch:doctor` has no repair or uninstall mode. It is safe to use as a final
read-only inventory before step 5, but its findings do not authorize deletion.
The isolated diagnostic key is removed by the probe and has a five-second
expiry; Hitch's ordinary rate-limit keys expire under their configured windows
and require no uninstall sweep.

Hitch does not ship a table-dropping removal migration. Keep the tables while
old deployments, queued jobs, logs, or audit workflows may still refer to
their IDs. If the application's owner later chooses deletion, create a host
migration that names each `hitch_*` table explicitly, take a final backup, and
review that irreversible operation independently. Do not reuse those table
names for unrelated data.

If the application may reinstall Hitch, retaining the tables and migration
history is safer than dropping them. Reinstall the same or a forward-compatible
version and run `bin/rails db:migrate`; never restore only part of the Hitch
schema.
