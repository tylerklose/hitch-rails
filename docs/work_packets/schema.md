# Work-packet schema

`ROADMAP.md` remains the milestone authority. `index.yml` is the
machine-readable transcription of its issue graph, command ownership, artifact
identity, and distribution policy; the verifier rejects any disagreement or a
public-capable artifact before the declared M5.4 gate.

H0 is the only packetless bootstrap node. Every other node has exactly one
`<issue>.md` file directly in this directory. A packet starts with
`# Work packet: <issue>` and contains these second-level headings, in order:

1. Scope
2. Not in scope
3. Target files/API
4. Dependencies
5. Acceptance commands
6. Evidence paths
7. Rollback
8. Estimate
9. Risks
10. Owner

Every body is nonempty and contains no unresolved placeholder marker. Commands
under `bin/` used in shell blocks are either Rails bootstrap commands or are
owned by the current issue or one of its transitive predecessors in
`index.yml`. Each redacted JSON evidence path mentioned by a packet must appear
in that packet's Evidence paths section, and a path may have only one owner.

`bin/verify-work-packets --graph PATH` writes deterministic JSON: H0 appears as
a node with a null packet and all other nodes name their packet. Edges point
from predecessor to dependent. No timestamps, machine paths, or repository URLs
enter the graph.

Schema version 2 adds `distribution_policy` and optional per-node `artifact`
metadata. Artifact versions are unique. `internal_only` checkpoints name only a
local package verifier; `public_optional`, `public_if_pre4_published`, and
`public_required` artifacts also name the public-download verifier. M5.4 must own
the first public-eligible version and the `published_pre4`/`deferred_to_final`
decision. For the 0.2 train, `published_pre4` remains historical schema context:
the accepted decision is `deferred_to_final`, active M6/M7 templates are
internal-only, and only final `0.2.0` may enter public preflight. M8 owns the
required final public release. A later packet may invoke a
verifier only when its creator is a transitive predecessor.
