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
5. If `config/hitch_mcp_install.json` exists, run
   `bin/rails destroy hitch:mcp:install` while the gem is still installed. The
   rollback verifies every generated file checksum and the exact marked route
   block before changing anything. If it refuses because an artifact was
   customized, review and remove those host-owned artifacts manually; do not
   bypass the refusal with blind recursive deletion.
6. Remove `mount Hitch::Engine` and any remaining host controller inclusions of
   `Hitch::ServerEndpoint` or `Hitch::CorsSupport`.
7. Remove `config/initializers/hitch.rb`, the Gemfile entry, and bundle again.

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
