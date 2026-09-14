# ADR 0008: The skills extension's Stage 1 shape

## Status

Proposed. Nothing is built. This records the Stage 1 ship shape and the
Stage 2 fast-follow door, and the three questions that gate starting.

## Context

MCP servers give agents tools. Tool descriptions say what a tool does, not
how to orchestrate several of them. Agent Skills fill that gap: a directory
with a required `SKILL.md` (YAML frontmatter plus instructions) and optional
scripts, references, assets, and images. The model loads metadata first,
instructions when the skill is activated, and supporting files only as the
task needs them. That progressive disclosure is a host job; this gem does
not put skill text into a model.

[SEP-2640](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2640)
binds that format onto MCP. The extension id is
`io.modelcontextprotocol/skills`. Each file in a skill directory is an MCP
resource, conventionally under `skill://`. A server that declares the
extension MUST implement `skills/list` and `skills/get`; files travel on
`resources/read`; `resources/directory/read` is optional and gated on
`directoryRead`. Nested skills are MAY: a descendant `SKILL.md` is supporting
content of the enclosing skill and MAY also be published as its own flat
list entry, so the same file can appear in both `resources` arrays.

The skill format itself — directory layout, frontmatter, and the rule that
the final path segment MUST equal frontmatter `name` — is delegated to the
[Agent Skills specification](https://agentskills.io/specification). This
gem would own only the Rails-shaped transport: which trees to scan, how
the catalog is snapshotted, and which methods the endpoint answers.

Today the endpoint is tools-only. `Protocol::METHODS` is
`server/discover`, `tools/list`, and `tools/call`. Skills expand that
allowlist only when opted in.

## Decisions

**Design for Stage 1+2, ship Stage 1, fast-follow Stage 2.** Stage 1+2
means one full-tree resource collector: when collecting files for a skill
directory, include every file under that tree, including files that would
belong to a nested skill. The refused alternative is a walker that stops
at a child `SKILL.md`. That collector would make Stage 1's nest refusal a
structural property of the walk, and Stage 2 would have to rewrite it to
dual-list. Building the complete walk now keeps Stage 2 a gate lift.

**Stage 1 ships that collector plus a fail-closed nest gate.** If a skill
directory contains a descendant `SKILL.md`, snapshot and doctor refuse with
an operator-clear message: nested skills are not supported yet; use a
sibling path under the namespace. Nested skills are MAY in the SEP, so
refusing the layout that would require dual-listing is still conformant.
Stage 2 lifts the gate and adds nest fixtures, tests, and docs: both skills
get flat `skills/list` entries; the parent's `resources` already includes
the child's files. No walker rewrite. No public API change.

**Opt-in via configured `skills_paths`, the same spirit as `mcp.enabled`.**
`skills_paths` is an array of roots. Empty or unset turns the extension
off: do not declare `io.modelcontextprotocol/skills`, and skill methods
stay unavailable (JSON-RPC `-32601`). The refused alternative is declaring
the extension with an empty catalog, which advertises a door the host did
not ask to open.

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
and the Agent Skills `name` field both require it. A mismatch is invalid;
the catalog does not invent a path that disagrees with the author.

**Tools stay an explicit Registry.** Skills are not registered with `skill:`
on Tool classes. There is no second Ruby Registry of skill classes. Tool
subclasses are not auto-discovered. ADR 0002's explicit allowlist exists
because tools are executable attack surface with OAuth scopes. Skills are
files. Collapsing those into one registration style would either auto-
discover executables or force operators to enumerate markdown by hand.

**The wire surface is the extension, two skill methods, and catalog-only
`resources/read`.** When skills are opted in, declare
`io.modelcontextprotocol/skills`, implement `skills/list` and `skills/get`,
and answer `resources/read` only for URIs in the skill catalog. There is
no general application VFS. Optional `resources/directory/read` is
deferred. Auth is the same MCP OAuth / endpoint gate as tools — no
separate dance. Protocol methods expand only while the extension is on;
with it off, today's tools-only allowlist is unchanged.

**Catalog snapshot lifecycle mirrors tools (ADR 0002).** Prepare one
immutable snapshot at `after_initialize` when the application eager-loads,
or on first MCP use otherwise. Clear it on reload. `hitch:doctor` prepares
explicitly while collecting facts. The refused alternative is reading the
filesystem on every `skills/list`: list entries, digests, and
`resources/read` bytes would be able to disagree.

**List and get entries carry `uri`, verbatim frontmatter as a JSON object,
and a complete `resources` array of `{uri, digest, size}`.** Digest is
`sha256:` plus 64 lowercase hex, of the bytes that `resources/read` will
serve. Prefer static files on disk over `"resources": "dynamic"`. The SEP
permits omitting `resources` only for generated content; hosts MAY decline
those skills. Hitch does not default to dynamic.

**Honor the SEP SHOULD limits in documentation and validation posture.**
Servers SHOULD NOT exceed 512 resources or 16 MiB total per skill,
including `SKILL.md`. Hosts MUST accept skills up to those limits and MAY
accept larger ones. Hitch's operator-facing check is how authors stay
inside the SHOULD.

**Out of scope, at every stage for now.** Hitch does not implement the
client half of progressive disclosure. It is not a skill CMS or authoring
UI. It does not default to `"resources": "dynamic"`. It does not reopen
ADR 0002.

## Implementation

Class boundaries and changes to shared code — including how
`Protocol::METHODS` grows a skills set beside the tools-only allowlist —
will be decided after the questions below are answered.

## Consequences

- An adopter who never sets `skills_paths` keeps today's tools-only
  endpoint. Declaring the extension is coupled to having roots to scan.
- Stage 1 adopters cannot nest a `SKILL.md` inside another skill. Sibling
  paths under a namespace (`billing/refunds` beside `billing/invoices`)
  are the supported layout until Stage 2 lifts the gate.
- Stage 2 does not change public configuration or the collector. Nest
  fixtures, tests, and docs are the work; dual-listing is already how the
  walk enumerates files.
- Skills do not become tools. Executable attack surface stays behind the
  explicit Registry; a markdown file cannot gain `.perform` by sitting in
  `skills_paths`.
- `resources/read` is not a filesystem proxy for the application. A URI
  outside the snapshot is not a skill file.
- No migration. No new table, no schema change, nothing for ADR 0005 to
  govern.
- Local tests can walk fixtures, refuse nested layouts, and check digests
  against served bytes. They do not prove a client loads a skill into a
  model.

## Removal and verification

Unsetting `skills_paths` undeclares `io.modelcontextprotocol/skills` and
leaves `skills/list`, `skills/get`, and catalog `resources/read` at
`-32601`.

Per docs/testing.md, local tests must exercise the real snapshot path and
refuse nested layouts rather than stubbing the walker. Three questions
gate starting implementation:

1. **What is the default `skills_paths` value?** Only `mcp/skills`, or
   empty until configured. Empty matches fail-closed opt-in. A Rails-ish
   default would make a conventional directory work without a knob, and
   would also declare the extension the moment that directory exists.

2. **What does an invalid `SKILL.md` under a configured root do?** Fail
   the whole snapshot, or skip that tree and doctor-warn. Fail-closed
   matches registry validation. Skipping would let one bad file leave the
   rest of the catalog available.

3. **Does `resources/directory/read` wait entirely until a client needs
   it?** The method is optional and gated on `directoryRead`. Deferring it
   is already the Stage 1 wire decision; this question is whether that
   deferral survives first contact with a client, or whether a named
   client forces the fast-follow.

## References

- [SEP-2640 Skills Extension](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/2640)
  (`io.modelcontextprotocol/skills`)
- [Skills extension overview](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/extensions/skills/overview.mdx)
- [ext-skills specification](https://github.com/modelcontextprotocol/ext-skills/blob/main/specification/stable/skills.mdx)
  · [Skills Over MCP working group](https://github.com/modelcontextprotocol/ext-skills)
- [Agent Skills specification](https://agentskills.io/specification)
- [ADR 0002](0002-registry-and-reload.md)
