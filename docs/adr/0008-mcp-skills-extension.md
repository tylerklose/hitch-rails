# ADR 0008: The skills extension's Stage 1 shape

## Status

Proposed. Nothing is built. This records the Stage 1 ship shape and the
Stage 2 fast-follow door after product review of the first draft.

## Context

MCP servers give agents tools. Tool descriptions say what a tool does, not
how to orchestrate several of them. Agent Skills fill that gap: a directory
with a required `SKILL.md` (YAML frontmatter plus instructions) and optional
scripts, references, assets, and images. The model loads metadata first,
instructions when the skill is activated, and supporting files only as the
task needs them. That progressive disclosure is a host job; this gem does
not put skill text into a model, and it never executes a skill file.

[SEP-2640](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2640)
binds that format onto MCP. The extension id is
`io.modelcontextprotocol/skills`. Each file in a skill directory is an MCP
resource, conventionally under `skill://`. A server that declares the
extension MUST implement `skills/list` and `skills/get`; files travel on
`resources/read`; `resources/directory/read` is optional in the SEP and
gated on `directoryRead`. Nested skills are MAY: a descendant `SKILL.md` is
supporting content of the enclosing skill and MAY also be published as its
own flat list entry, so the same file can appear in both `resources` arrays.

The skill format itself — directory layout, frontmatter, and the rule that
the final path segment MUST equal frontmatter `name` — is delegated to the
[Agent Skills specification](https://agentskills.io/specification). This
gem would own only the Rails-shaped transport: which trees to scan, how
the catalog is snapshotted, and which methods the endpoint answers.

Today the endpoint is tools-only. `Protocol::METHODS` is
`server/discover`, `tools/list`, and `tools/call`. Skills expand that
allowlist only when the skills extension is on.

## Decisions

**Design for Stage 1+2, ship Stage 1, fast-follow Stage 2.** Stage 1+2
means one full-tree resource collector: when collecting files for a skill
directory, include every file under that tree, including files that would
belong to a nested skill. The refused alternative is a walker that stops
at a child `SKILL.md`. That collector would make Stage 1's nest refusal a
structural property of the walk, and Stage 2 would have to rewrite it to
dual-list. Building the complete walk now keeps Stage 2 a gate lift.

**Stage 1's nest gate omits, it does not abort Rails.** A descendant
`SKILL.md` is not a supported Stage 1 layout. Omit the enclosing skill from
the published catalog, and do not publish the nested directory as its own
skill until Stage 2. `hitch:doctor` names the path and the reason (nested
skills are not supported yet; use a sibling path under the namespace).
Other valid skills still publish. MCP tools and Rails boot keep working.
Nested skills are MAY in the SEP, so omitting the layout that would require
dual-listing is still conformant. Stage 2 lifts the gate and adds nest
fixtures, tests, and docs: both skills get flat `skills/list` entries; the
parent's `resources` already includes the child's files. No walker rewrite.
No public API change.

**Default `skills_paths` is `[app/skills]`.** That is Rails-shaped, parallel
to hitch's `app/tools`. An explicit empty array disables the skills
extension: do not declare `io.modelcontextprotocol/skills`, and skill
methods stay unavailable (JSON-RPC `-32601`). The default path with
`mcp.enabled` declares the extension even when the catalog is empty — an
empty listing is SEP-legal. The refused alternative is empty-until-
configured, which would make a conventional `app/skills` tree inert until
someone set a knob. Consolidation under `app/mcp/{tools,skills}` is out of
scope; this ADR does not rename tools.

**Discovery is Rails-shaped path namespaces, not a second Ruby registry.**
Under each configured root, every directory with a valid `SKILL.md` is a
skill. The relative path from the root is the skill-path; intermediate
directories without `SKILL.md` are namespace-only. Organizational prefixes
are allowed: `billing/refunds` becomes `skill://billing/refunds/…`. A
skill is a directory, not a lone markdown file: `SKILL.md` is required;
optional scripts, references, assets, and images are each an MCP resource.
This is how Rails finds models and controllers — a tree of files — not how
this gem finds tools.

**The final skill-path segment MUST equal frontmatter `name`.** SEP-2640
and the Agent Skills `name` field both require it. A mismatch is invalid
and is omitted from the catalog like any other invalid skill.

**Tools stay an explicit Registry.** Skills are not registered with `skill:`
on Tool classes. There is no second Ruby Registry of skill classes. Tool
subclasses are not auto-discovered. ADR 0002's explicit allowlist exists
because tools are executable attack surface with OAuth scopes. Skills are
files. Collapsing those into one registration style would either auto-
discover executables or force operators to enumerate markdown by hand.

**An invalid `SKILL.md` is view-shaped: omit that skill, keep the rest.**
The catalog publishes every valid skill. `hitch:doctor` warns or fails with
the path and reason. Rails boot and MCP tools keep working. The refused
alternative is taking down the whole skills catalog — or the whole Rails
boot — for one bad file. That is louder than the defect. Registry
validation stays fail-closed for tools because a bad tool class is
executable attack surface; a bad markdown file is not.

**Wire failures for a published skill fail that request closed.** If
`skills/get`, `resources/read`, or `resources/directory/read` cannot serve
honestly — missing file, digest or size drifting from the snapshot, path
not in the catalog — refuse the request. Do not serve bytes that disagree
with the snapshot. Other skills are unaffected. The refused alternative is
returning drifted disk contents under a digest the listing already promised.

**The Stage 1 wire surface is the extension, two skill methods, and
catalog-only resources.** When the skills extension is on, declare
`io.modelcontextprotocol/skills` with `directoryRead: true`, implement
`skills/list` and `skills/get`, and answer `resources/read` and
`resources/directory/read` only for URIs in the skill catalog (skill roots
and subdirectories in the snapshot). Advertise the minimal `resources`
capabilities those methods require on `server/discover`. There is no
general application VFS; resources exist for the skills catalog. Directory
read is navigation for trees we already serve, not nested-skill work.
Complete `resources` arrays on list/get remain; directory/read is
additional. Auth is the same MCP OAuth / endpoint gate as tools — no
separate dance. Protocol methods expand only while the extension is on;
with it off, today's tools-only allowlist is unchanged.

**Catalog snapshot lifecycle mirrors tools (ADR 0002).** Prepare one
immutable snapshot at `after_initialize` when the application eager-loads,
or on first MCP use otherwise. Clear it on reload. `hitch:doctor` prepares
explicitly while collecting facts. The refused alternative is reading the
filesystem on every `skills/list`: list entries, digests, and served bytes
would be able to disagree.

**List and get entries carry `uri`, verbatim frontmatter as a JSON object,
and `resources`.** `resources` is always required: a complete array of
`{uri, digest, size}`, or the string `"dynamic"`. Digest is `sha256:` plus
64 lowercase hex, of the bytes that `resources/read` will serve. Hitch
prefers static files on disk and does not default to `"dynamic"`. The
field is not omitted.

**`skills/list` carries SEP-2549 list-caching attributes.** For protocol
`2026-07-28`, that is the same stamp `tools/list` already ships:
`ttlMs`, `cacheScope`, and `resultType: "complete"`.

**Skills filter like tools, deny-default.** List, get, read, and
directory/read are principal-aware. Scopes are declared on the skill as
frontmatter `metadata.io.hitch/scopes`: a space-separated string of the
same scope strings `register ToolClass, scopes: [...]` already uses
(`mcp`, and any other string in `supported_scopes`). A principal sees a
skill only when every declared scope is granted, the same static-scope
filter as ADR 0003. A skill with no or empty scopes is visible to no one
— omitted for every principal — and doctor may warn. A host-level default
(the analogue of a `before_action`) is a future escape hatch, not Stage 1.
The refused alternative is "the same MCP token sees every skill."

**Duplicate skill-paths across roots fail closed.** No last-wins. Omit the
ambiguous skill-path from the published catalog on both sides.
`hitch:doctor` names the colliding roots and paths. Unique skill-paths
from those roots still publish.

**Stage 1 refuses symlinks.** Also refuse any path whose realpath escapes
the configured skills root. The SEP is silent on server-side symlinks;
this is hitch policy. The refused alternative is allowing realpath-
chrooted symlinks by default, which would make "a file under the skill
tree" mean something the operator cannot see from the directory listing.

**Scripts are data.** Hitch never executes `scripts/` or any other skill
file. It serves bytes. Execution is a client/host concern; the SEP's
security rules forbid implicit local execution.

**Honor the SEP SHOULD limits in documentation and validation posture.**
Servers SHOULD NOT exceed 512 resources or 16 MiB total per skill,
including `SKILL.md`. Hosts MUST accept skills up to those limits and MAY
accept larger ones. Hitch's operator-facing check is how authors stay
inside the SHOULD. Exceeding them is an invalid skill in the view-shaped
sense: omit that skill, doctor the path and reason, leave the rest.

**Out of scope, at every stage for now.** Hitch does not implement the
client half of progressive disclosure. It is not a skill CMS or authoring
UI. It does not default to `"resources": "dynamic"`. It does not reopen
ADR 0002. It does not rename `app/tools` into `app/mcp/`.

## Implementation

Class boundaries and changes to shared code — including how
`Protocol::METHODS` grows a skills set beside the tools-only allowlist —
belong to the implementation PR. The ship shape above is the constraint.

## Consequences

- An adopter who leaves `skills_paths` at the default and enables MCP
  declares the skills extension. An empty `app/skills` tree is a legal
  empty catalog, not a disabled extension. An explicit `skills_paths = []`
  is how to keep today's tools-only allowlist.
- Stage 1 adopters cannot nest a `SKILL.md` inside another skill. Sibling
  paths under a namespace (`billing/refunds` beside `billing/invoices`)
  are the supported layout until Stage 2 lifts the gate. A nested layout
  omits that tree from the catalog; it does not take down the app.
- Stage 2 does not change public configuration or the collector. Nest
  fixtures, tests, and docs are the work; dual-listing is already how the
  walk enumerates files.
- Skills do not become tools. Executable attack surface stays behind the
  explicit Registry; a markdown file cannot gain `.perform` by sitting in
  `skills_paths`. Hitch will not run `scripts/`.
- A skill without `io.hitch/scopes` is published to nobody. That is the
  same deny-default as an unimplemented `available_to?`, applied to files.
- `resources/read` and `resources/directory/read` are not a filesystem
  proxy for the application. A URI outside the snapshot is not a skill
  file.
- No migration. No new table, no schema change, nothing for ADR 0005 to
  govern.
- Local tests can walk fixtures, omit nested and invalid layouts, refuse
  drifted bytes, and filter by principal. They do not prove a client loads
  a skill into a model.

## Removal and verification

An explicit empty `skills_paths` undeclares `io.modelcontextprotocol/skills`
and leaves `skills/list`, `skills/get`, `resources/read`, and
`resources/directory/read` at `-32601`.

Per docs/testing.md, local tests must exercise the real snapshot path
rather than stubbing the walker. They must omit nested layouts and invalid
`SKILL.md` files without taking down other skills or boot, refuse symlink
and realpath-escape, omit both sides of a colliding skill-path, and refuse
a get/read whose bytes no longer match the snapshot.

This stays Proposed because nothing is implemented, not because product
questions remain.

## References

- [SEP-2640 Skills Extension](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2640)
  (`io.modelcontextprotocol/skills`)
- [Skills extension overview](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/extensions/skills/overview.mdx)
- [ext-skills specification](https://github.com/modelcontextprotocol/ext-skills/blob/main/specification/stable/skills.mdx)
  · [Skills Over MCP working group](https://github.com/modelcontextprotocol/ext-skills)
- [Agent Skills specification](https://agentskills.io/specification)
- [SEP-2549](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/seps/2549-TTL-for-list-results.md)
  (list-caching attributes on protocol `2026-07-28`)
- [ADR 0002](0002-registry-and-reload.md) · [ADR 0003](0003-tool-policy-and-errors.md)
