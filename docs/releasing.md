# Releasing

`rake release` refuses to run with any uncommitted tracked change, and
`bin/ci` rewrites the two appraisal lockfiles as soon as the version changes.
So the commit comes after the gate, not before.

1. Bump `lib/hitch/version.rb`. A `.pre`/`.dev` suffix makes the gem a
   RubyGems *prerelease*: `gem install hitch-rails` will not find it, and the
   README's `gem "hitch-rails"` will not resolve. Release versions carry no
   suffix.
2. Date the version's `CHANGELOG.md` heading.
3. Run `bin/ci`. It rewrites `gemfiles/*.gemfile.lock`, which are tracked.
4. Run `bin/mutation-mcp` if any mutation subject changed since the last
   release (see the subject list in `test/contracts/`).
5. Commit all four files — `lib/hitch/version.rb`, `CHANGELOG.md`, and both
   `gemfiles/*.gemfile.lock` — and push `main`.
6. `bundle exec rake release` — builds the gem, creates the annotated
   `vVERSION` tag, pushes the branch and tag, and publishes to RubyGems.
   `rubygems_mfa_required` is set, so this prompts for an OTP.
7. `bin/release-check VERSION` — verifies the published RubyGems bytes match
   the tag exactly. Allow a minute for CDN propagation; `gem fetch` can 404
   briefly right after a push.
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
