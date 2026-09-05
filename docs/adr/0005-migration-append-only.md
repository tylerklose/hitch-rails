# ADR 0005: Ship migrations append-only, and never edit a shipped one

## Status

Accepted as of the second migration (`20260822000000_add_hitch_refresh_tokens`).
Revisit at roughly five or six migrations, or at a 1.0 boundary.

## Context

Hitch does not copy migrations into the host. `Hitch::Engine`'s
`:append_migrations` initializer adds the engine's `db/migrate` to the host's
migration paths, so an adopter runs `bin/rails db:migrate` and gets everything
— no install task, nothing to re-run on upgrade. That is a deliberately good
install story and the reason the install generator writes only an initializer.

It has one consequence that is easy to miss and expensive to discover: the
engine's migration files *are* the host's migrations, under the engine's own
timestamps. Editing a shipped migration in place would apply to a fresh
install, and silently not apply to every existing one, whose
`schema_migrations` already records that version. The two populations would
diverge with nothing detecting it — no error, no pending migration, just a
column some databases have and others do not.

The cost of append-only is that a fresh install replays the full history. At
two migrations that is nothing. It becomes worth addressing somewhere in the
handful-of-migrations range.

Rails solves this for Active Storage by *copying* rather than appending, which
buys the freedom to rewrite:

```
activestorage/db/
├── migrate/            # ONE file, timestamp frozen in 2017, edited in place
└── update_migrate/     # per-change deltas for existing installs
```

`active_storage:install` copies the consolidated file, so a new app gets
current state in one migration. `active_storage:update` points
`MIGRATIONS_PATH` at `update_migrate` and copies only the deltas. The 2017 file
contains `service_name` and `variant_records`, both Rails 6.1 additions,
despite its timestamp.

## Decision

Append only. Every schema change is a new migration file with a new timestamp.
A migration that has shipped in a released gem is immutable — including
comments, so a diff never invites the question.

Do not adopt the copy-based split yet. Trading an install story where
`bin/rails db:migrate` simply works, in order to save replaying two files, is a
bad exchange at this size.

When the history does get long enough to matter, two options, in preference
order:

1. **Squash behind a guard.** Consolidate into one migration that no-ops when
   the schema is already present, and pre-seed `schema_migrations` with the
   superseded versions so existing installs skip it. Keeps the append-based
   install story intact. The `squasher` gem automates this and supports
   engines.
2. **Adopt the Active Storage split.** `db/migrate` consolidated plus
   `db/update_migrate` deltas, with install and update tasks. Only worth it if
   we also want copy-based installs for other reasons.

If option 2 is ever taken, the consolidated file and the sum of the deltas must
produce identical schemas forever, and that invariant needs a test rather than
discipline: apply consolidated, dump; apply base plus deltas, dump; assert
equal.

## Consequences

A fresh install replays every migration, and that number only grows until a
squash. The engine cannot ship a "current state" migration for new adopters
while remaining append-based.

Any change to an existing table is an `add_column` / `change_table` migration,
never an edit — including corrections to a migration that shipped with a
mistake. The correction is itself a new migration.

`Hitch::Doctor`'s `migration_facts` derives its required-version list from the
engine's `db/migrate/*.rb` directory rather than a hardcoded array, so a new
migration is picked up with no change and an adopter who forgets to migrate
gets `migrations: fail / missing`. Keep it derived; a hardcoded list would
have to be updated in lockstep and would silently pass when it was not.

## Removal and verification

The append mechanism is documented in `lib/hitch/engine.rb`'s
`:append_migrations` initializer, which also explains the `ENGINE_ROOT` guard
against duplicate migration paths. `bin/ci` runs all release lanes, and the
sqlite lane applies every migration from scratch; `bin/package-smoke` builds
the gem and adopts it into a disposable Rails app, so a migration that does not
ship or does not apply fails there rather than in an adopter's terminal.
