# Releasing

`rake release` refuses to run with any uncommitted tracked change, and
`bin/ci` rewrites the two release-lane lockfiles as soon as the version
changes.
So the commit comes after the gate, not before.

1. Bump `lib/hitch/version.rb`. A `.pre`/`.dev` suffix makes the gem a
   RubyGems *prerelease*: `gem install hitch-rails` will not find it, and the
   README's `gem "hitch-rails"` will not resolve. Release versions carry no
   suffix.
2. Date the version's `CHANGELOG.md` heading.
3. Run `bin/ci`. It rewrites the two release-lane lockfiles, which are
   tracked. (`gemfiles/rails_main_sqlite.gemfile` has no tracked lockfile —
   the edge lane resolves Rails main fresh each run.)
4. Run `bin/mutation-mcp` if any mutation subject changed since the last
   release (see the subject list in `test/contracts/`).
5. Commit all four files — `lib/hitch/version.rb`, `CHANGELOG.md`,
   `gemfiles/rails_8_0_sqlite.gemfile.lock`, and
   `gemfiles/rails_8_1_postgresql.gemfile.lock` — and push `main`.
6. `bundle exec rake release` — builds the gem, creates the annotated
   `vVERSION` tag, pushes the branch and tag, and publishes to RubyGems.
   `rubygems_mfa_required` is set, so this prompts for an OTP.
7. `bin/release-check VERSION` — verifies the published RubyGems bytes match
   the tag exactly. It fetches with its own empty spec cache, so a "could not
   find a valid gem" from it is real CDN propagation and clears within a
   minute. `gem fetch` or `gem install` run by hand reports those same words
   off a stale index, for far longer than waiting fixes; that one is
   `gem sources --clear-all`.
8. Publish a GitHub release for the tag, pointing at the CHANGELOG entry.

When the minor version changes, `docs/public_api/<version>.md` is a new file
and the gemspec names the old one twice — in `spec.files` and in
`documentation_uri`. Both need updating.
`Hitch::PackageIntegrityTest` derives the expected filename from
`Hitch::VERSION` and fails if either reference is stale, so `bin/ci` catches a
half-done bump rather than shipping one.

An upgrade that needs adopter action — a migration, a changed default, a
removed method — also wants `docs/upgrading/<from>-to-<to>.md`, packaged in
`spec.files` and linked from the CHANGELOG entry. It is what an adopter's
agent reads to perform the upgrade.
