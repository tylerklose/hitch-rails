# Releasing

1. Bump `lib/hitch/version.rb` and date the version's `CHANGELOG.md` section.
2. Run `bin/ci`.
3. `bundle exec rake release` — builds the gem, creates the annotated
   `vVERSION` tag, pushes it, and publishes to RubyGems.
4. `bin/release-check VERSION` — verifies the published RubyGems bytes match
   the tag exactly.
