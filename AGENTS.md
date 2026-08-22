# Working in this repository

Read this before writing code here. It is about *how* to work in Hitch, not
what Hitch is — the README covers that, and [CONTRIBUTING.md](CONTRIBUTING.md)
draws the line between what this gem owns and what the host application owns.

## Posture

Say the thing. Skip the preamble, skip the summary of what you are about to do,
and skip telling anyone a plan is comprehensive.

Simple beats clever, every time. If a change is hard to explain, it is probably
the wrong change. Elegance here means someone reading the diff in a year
understands it without asking you.

Do not overcomplicate. Most tasks in this repository are smaller than they first
look, and the ones that are genuinely large announce themselves. If your
solution is much bigger than the problem, stop and say so rather than building
your way through it.

Report what actually happened. If the tests fail, say so and show the output. If
you skipped something, say what and why. Finished means finished and verified —
not "should work."

## Prove it by breaking it

This is the one habit that matters most here, and it is not optional.

A test that passes with a protection in place proves nothing. Remove the
protection, watch the test go red, put it back. If it stays green, the test was
never testing what its name claims.

This is not theoretical. Every one of these shipped in this repository:

- A generator test that asserted generated code was valid Ruby, while the
  generated tests could not pass.
- A test suite that ran generated tests over HTTPS for a reason no adopter's
  suite supplies, so a template that only worked here looked correct.
- A verifier that compared a published gem against an empty allowlist, and so
  could only ever fail — its false alarm indistinguishable from a real finding.
- A boot fix whose unit tests stubbed the exact call whose *timing* was the
  defect. They passed. Production died on the first deploy.

Two rules fall out of that. **Do not stub the thing under test** — drive the
layer that really runs, even when that means a subprocess and a real boot. And
**be suspicious of a test that passes the first time**, especially one you wrote
to cover a bug you just fixed.

## Where the coverage lies to you

`test/dummy` configures most settings explicitly. So the fall-back-to-the-
default paths — which is what every adopter actually gets — execute nowhere in
the suite. Production-only code is doubly hidden, because no in-process test
reaches it at all.

When you touch a default, a fallback, or anything behind
`Rails.env.production?`, assume the suite is blind to it until you have proven
otherwise. `test/hitch/production_boot_test.rb` exists because unit tests could
not reach that path.

## Conventions

Rails-native, always. Use the framework's own idioms and Rails' own vocabulary.
Do not invent a pattern where a convention exists. When there is a real
trade-off, ask what 37signals would ship in Basecamp — the answer is usually the
smaller, more boring one.

Spec conformance is the correctness bar. This gem implements OAuth 2.1 and the
MCP authorization profile; cite the RFC or the spec section in comments and
commit messages when behavior turns on it.

Match the surrounding voice. Comments explain *why*, briefly, and are rare
enough that each one earns its place. Read the neighbors before you write.

Security posture fails closed. Tools are hidden until registered, origins
refused until listed, credentials stored as digests and never logged. Where a
default deliberately breaks that pattern, it is documented next to the reason.
Do not quietly add a second exception.

Migrations are append-only. A shipped migration is an adopter's migration —
editing one applies to fresh installs and silently skips every existing one.
Corrections are new migrations. See
[ADR 0005](docs/adr/0005-migration-append-only.md).

## Finishing

Run `bin/rubocop` and `bin/rails test`. Run `bin/ci` for anything touching
schema, packaging, or boot — it covers both release lanes and builds the gem
into a disposable application.

Then make one simplification pass: could this be smaller? Answer it by removing
things, never by weakening what the code guarantees. Stop when a pass yields
nothing.

Do not commit, push, tag, or publish unless asked. Releases are a maintainer
decision — see [docs/releasing.md](docs/releasing.md).
