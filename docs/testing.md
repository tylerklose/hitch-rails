# Testing here

Read this before you write a test in this repository.

## Prove it by breaking it

Remove the protection, watch the test go red, put it back. If it stays green
with the protection gone, the test never tested what its name claims.

Two rules follow. **Don't stub the thing under test** — drive the layer that
really runs, even when that means a subprocess and a real boot. And **distrust
a test that passes the first time**, especially one you wrote for a bug you
just fixed.

## The four that shipped

- **Parsing is not running** (`a36ed2d`, `b008f4b`). `install_generator_test`
  asserted the generated files were valid Ruby. They were. The generated
  *tests* failed on every realistic configuration, and two developers hit it
  before this suite did.
- **A harness the adopter doesn't have** (`b008f4b`). The generated tests ran
  over HTTPS because our `test_helper` sets `https!`, not because the template
  worked. Removing the fix left it green — six passing assertions proving
  nothing.
- **A verifier that could only fail** (`ef4328a`). `bin/release-check` loaded
  the gemspec where `git ls-files` couldn't run, so the allowlist came back
  empty and the comparison reduced to `published == []`. On a byte-perfect
  publish it printed the same words it would print for a smuggled file.
- **Stubbing the timing** (`5f173f5`). The rate-limit boot check's unit tests
  stubbed `RateLimitStore.resolve` — the call whose *ordering* was the defect.
  They passed. They would have passed over the fix too. Production died on the
  first deploy.

## Where the suite is blind

`test/dummy` sets most config explicitly, so the fall-back-to-the-default
paths — what every adopter actually gets — execute nowhere. Production-only
code is worse off: no in-process test reaches it at all.

Touch a default, a fallback, or anything behind `Rails.env.production?` and
assume you have no coverage until you've proven otherwise.
`test/hitch/production_boot_test.rb` exists because unit tests could not reach
that path; it boots a real application in a real subprocess.

## What each lane proves

| Command | What only it proves |
| --- | --- |
| `bin/rails test` | The suite, one lane, synthetic stores. |
| `bin/ci` | Both release lanes, eager loading, migrations, the built gem installed into a disposable app, and the Redis fallback lane below. |
| `bin/ci-rate-limit` | The rate-limit store resolving to a real Redis, including the production boot fallback. Needs Docker. |
| `bin/package-smoke` | The built artifact — not the checkout — driving generators, doctor, and the OAuth + MCP flow. |
| `bin/conformance-auth` | The official authorization profiles. Runs in CI outside `bin/ci`. |

When you add a gate, say what it uniquely proves. If nothing, delete it.
