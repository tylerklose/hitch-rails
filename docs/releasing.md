# Releasing Hitch 0.2

Hitch's release rail separates evidence, artifact readiness, publication
authority, publication, and live reconciliation. A green final check does not
authorize a tag or RubyGems upload.

The recorded M5.4 decision defers public RubyGems publication through the
internal RC train. That decision is resolved, not a branch that may be reopened
later in this train. `0.2.0` is the first public release and remains unpublished
until every M8 readiness gate and separate publication authority pass. Do not
publish `0.2.0.pre.4`, `0.2.0.rc1`, or `0.2.0.rc2`.

## Evidence trust boundary

`bin/verify-release-evidence` proves the checked-in ledger's shape, ordering,
source/artifact bindings, and internal consistency. It cannot independently
authenticate a private host command, Tyler's approval, a product-client run, or
a maintainer review from JSON alone. The trust root for those attestations is
protected, human-reviewed Hitch Git history plus review of the referenced
private reports. Provider-backed and live commands separately verify GitHub,
tag, and RubyGems state where those systems are in scope. Never describe a
locally valid manifest as independent proof that an external act occurred.

## Evidence authoring

Copy the matching file from `docs/evidence_templates/0.2.0` to a private scratch
location. Draft validation checks shape without treating placeholders as facts:

```sh
bin/validate-release-evidence-draft KIND /path/to/draft.json
bin/validate-release-evidence-draft --ready KIND /path/to/draft.json
```

Review the actual source, command output, private report, approval, and
redaction. Then place the record at the exact path in
`docs/contracts/release_evidence.yml`, change only its index entry from pending
to accepted, pin the file SHA-256, and run `bin/verify-release-evidence`. The
main verifier, not the draft validator, is acceptance authority.

M6 and M7 adoption occur only in a separate process with Tyler-granted host and
deployment access. The framework process does not enter or update Skillit. M6
must use the accepted pre4 bytes and preserve copied-lineage semantics; M7 must
use the accepted RC1 bytes and prove independent ancestry and policy mapping.
Each checkpoint records exact commit, tree, gem name, and SHA-256. RC1 descends
strictly from the accepted pre4 source. Adoption deltas include the gemspec;
`lib/hitch/version.rb` is mechanical only when normalizing the exact expected
version literal makes the complete before/after files identical. A claimed red
test commit may contain no framework or dependency implementation added since
the milestone input.

## Private checkpoint handoff

The prerelease train stays off RubyGems. Materialize accepted internal bytes in
an existing directory outside the repository:

```sh
mkdir -p /tmp/hitch-private-checkpoints
bin/prepare-release-artifact --checkpoint 0.2.0.pre.4 /tmp/hitch-private-checkpoints
# After M6 is accepted, stage 0.2.0.rc1 the same way for M7.
shasum -a 256 /tmp/hitch-private-checkpoints/hitch-rails-*.gem
```

The command reads accepted indexed evidence, rebuilds the exact commit/tree,
checks the recorded SHA-256 and internal-only status, verifies the source stayed
unchanged, and publishes the output exclusively. It performs no tag, network,
or RubyGems action. Transfer only through an authenticated private channel;
the receiving host verifies the advertised digest before `gem install --local`
or ingestion into an access-controlled internal gem source. The adoption
record binds Tyler's approval to an opaque stable repository identity and input
artifact digest, and records the exact installed artifact name and digest.

Generate the milestone-owned local reports from the sealed RC source instead
of hand-writing a command and hash:

```sh
HITCH_MILESTONE_LOCAL_GATE_REPORT=/tmp/m6-package-smoke.json \
  bin/milestone-local-gate M6 package_smoke
HITCH_MILESTONE_LOCAL_GATE_REPORT=/tmp/m7-mutation-mcp.json \
  bin/milestone-local-gate M7 mutation_mcp
```

Each command runs only its fixed gate, binds the generated report to the clean
checkpoint source and gem SHA-256, verifies postconditions before writing, and
uses an exclusive external destination. Copy that generated report object into
the corresponding adoption manifest and use the file's SHA-256 as the gate
digest. M7's approval-bound host identity and private report must differ from
M6's; each pinned product client likewise needs its own report.

## Final candidate

After M6 and M7, prepare one clean source commit whose version and public
documents describe final `0.2.0`. Materialize its source-bound bytes outside
the repository, then obtain Tyler's explicit approval and run both pinned
product clients against a disposable loopback host using those exact bytes.
Each sanitized record must prove PKCE authorization, resource discovery,
tools/list, tools/call, scope step-up, expected result identity, and zero
production mutation. Record each client's start and completion timestamps so
the verifier can prove every run began after approval and finished before
verification. Product runs remain forbidden until that approval exists.

```sh
mkdir -p /tmp/hitch-0.2.0-product-candidate
bin/prepare-release-artifact --candidate 0.2.0 /tmp/hitch-0.2.0-product-candidate
```

Candidate preparation requires accepted M7 evidence, a clean HEAD, final public
documents, and an existing external directory. It records no publication
authority and performs no tag or upload.

After accepting the product-client record, verify the four-lane contract and
capture local gates outside the repository:

```sh
bin/verify-release-matrix
HITCH_FINAL_LOCAL_GATES_REPORT=/tmp/hitch-0.2.0-local-gates.json bin/final-local-gates
```

`bin/final-local-gates` rebuilds the candidate, runs the fixed CI,
conformance, packaged-app, automated-client, mutation, and documentation gates,
retains only output and structured-report digests, refuses a dirty or changed
worktree/HEAD/tree, and writes the report once. It also forces test mode,
removes generic `DATABASE_URL`/`SCHEMA` authority, and proves package/client
reports name the candidate artifact SHA and source commit/tree. Review the
exact GitHub Actions push run separately and record its canonical repository,
candidate head SHA, run/attempt, workflow blob SHA, and four distinct contracted
jobs in `hosted-matrix.json`. Pull-request runs do not qualify because the
default checkout tests a synthetic merge commit rather than the candidate head.
The hosted run and each local gate must begin after product-client evidence is
accepted; later verification timestamps cannot repair an early execution.

Accept both candidate-bound reports, then author `final-check.json` with every
indexed prerequisite. The final check's local gates all bind the one generated
local report; `all_matrix_lanes` binds the hosted report. Record a named
`release_maintainer` review only after every bound prerequisite's authoritative
`verified_at`, `recorded_at`, or `verified_on` completion value. Date-only
values are conservatively ordered at the end of that day. The final source must
have no runtime or public-API drift from RC2 other than an exact version-literal
change with all other version-file bytes unchanged. That review attests that
the generated local report came from the documented exclusive command, not
merely that its hashes have the right shape. Completion-field ownership is
exact per prerequisite kind: another temporal
field cannot replace a missing or malformed authority. The deterministic
work-packet graph uses the separately bound
`work_packet_verification.verified_on` value as its completion authority only
when that companion's graph path and SHA-256 match the accepted graph record.

Then confirm readiness and materialize review bytes in a new external
directory:

```sh
bin/verify-release-evidence --ready-for-authority 0.2.0
mkdir -p /tmp/hitch-0.2.0-authority-review
bin/prepare-release-artifact --ready-for-authority 0.2.0 /tmp/hitch-0.2.0-authority-review
```

The staged gem must contain a dated `0.2.0` changelog heading, the exact README
public-status and four-lane language, public installation, supported `0.2.x`
security row, final API and upgrade status wording, an empty current Unreleased
changelog section, the ROADMAP status
`> Status: completed for the public \`0.2.0\` release.`, and final framework
metadata, the exact final version, and no test, evidence, work-packet, credential, or
repository-only release tooling paths.

## Publication authority and publication

A named release authority, Tyler Klose, reviews the printed candidate identity,
staged bytes, and final-check digest. Only Tyler creates and accepts
`final-publication-authority.json` for the exact version, artifact SHA, source
commit/tree, tag, and final-check SHA. Then rerun:

```sh
bin/verify-release-evidence --preflight 0.2.0
bin/release-check --validate-version 0.2.0
mkdir -p /tmp/hitch-0.2.0-authorized
bin/prepare-release-artifact 0.2.0 /tmp/hitch-0.2.0-authorized
```

Create annotated `v0.2.0` at the authorized commit and publish only the gem
materialized by the authorized staging command. These are deliberate maintainer
actions; no repository command creates a tag or uploads to RubyGems.

## Download and live completion

After publication, generate the downloaded-byte report outside the repository:

```sh
HITCH_RELEASE_REPORT=/tmp/hitch-0.2.0-downloaded.json bin/release-check 0.2.0
```

Review and accept that generated record at its indexed path. Completion is the
live command, not the presence of a handwritten JSON file:

```sh
bin/release-check --complete 0.2.0
```

It reruns the local and canonical-GitHub annotated-tag object/peeled-target
checks plus the RubyGems download checks, compares every
immutable field with the accepted downloaded-gem record, and revalidates the
ledger without changing the worktree. If immutable public bytes are wrong,
yank when appropriate and forward-fix under a new version; never rewrite a tag
or published gem.
