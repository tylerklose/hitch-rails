# Working in this repository

Simple beats clever. If a change is hard to explain, it's the wrong change.
If your solution is bigger than the problem, say so instead of building it.
Skip the preamble, skip the summary, skip telling anyone a plan is thorough.

Say what actually happened. Tests failed — say so and show the output. Skipped
something — say what. Finished means finished and verified, not "should work."

Rails-native. Use the framework's own vocabulary and don't invent a pattern
where a convention exists. On a real trade-off, ship what Basecamp would.

Fail closed. Tools hidden until registered, origins refused until listed,
credentials digested and never logged. One default breaks that on purpose,
documented where it's set. Don't add a second.

Cite the RFC or spec section when behavior turns on it. This gem implements
OAuth 2.1 and the MCP authorization spec; conformance is the correctness bar.

Comments explain why, briefly, and are rare enough to earn their place. Read
the neighbors before you write.

A green suite proves nothing about defaults, fallbacks, or production-only
paths — none of them execute here.

## Before you

| … do this | … read this |
| --- | --- |
| Write a test, or touch a default, fallback, or production path | [docs/testing.md](docs/testing.md) |
| Change the schema | [ADR 0005](docs/adr/0005-migration-append-only.md) — migrations are append-only |
| Add public API | [CONTRIBUTING.md](CONTRIBUTING.md) — what this gem owns and what the host owns |
| Release | [docs/releasing.md](docs/releasing.md) |

## Finishing

Run `bin/rubocop` and `bin/rails test`. Run `bin/ci` for anything touching
schema, packaging, or boot.

Then one pass: could this be smaller? Answer it by removing things, never by
weakening what the code guarantees. Stop when a pass yields nothing.

Don't commit, push, tag, or publish unless asked.
