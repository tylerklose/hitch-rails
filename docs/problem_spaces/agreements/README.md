# Agreement systems: the problem space

> **Status:** exploratory problem-space document. This is not shipped Hitch
> behavior, a public API proposal, a legal-compliance claim, or an active Hitch
> roadmap milestone.

This document lives in the Hitch repository because authenticated tools may
eventually expose agreement operations. It does **not** imply that agreement
records belong in Hitch core. Hitch owns authenticated MCP mechanics; a future
agreement kernel would own business records and ceremonies and would likely be
a separate companion library if extraction evidence justifies one.

## The thesis

The reusable concept is not a proposal, contract template, signature widget,
or generic document manager.

It is the relationship created when the required parties assent to one exact
document revision:

```text
Agreement = immutable DocumentRevision + required Parties + attributed Assents
```

That formulation separates truths that applications routinely collapse:

- a document can exist without anyone agreeing to it;
- a proposal can be issued while agreement remains pending;
- one party can assent while another has not;
- a legal entity can be the bound party while a human signs on its behalf;
- a signature can be genuine but attached to stale or incomplete terms;
- a later revision does not change what the parties previously accepted; and
- an invoice, authorization, acknowledgement, payment, and receipt are not all
  agreements merely because each may involve a document or button.

The framework-sized operation is therefore:

> Bind an exact immutable set of terms to a snapshotted party roster, collect
> attributable assent under a defined acceptance rule, and create durable
> agreement evidence when that rule is satisfied.

## Why this is difficult

A single-signer happy path is easy: render terms, collect a typed name, and set
`signed_at`. The real problem appears as soon as the system must answer any of
these questions:

- Which exact bytes, structured terms, attachments, and renderer version did
  the signer see?
- Did a link-preview bot count as delivery or acceptance?
- Was the person signing for themselves or for a company?
- What evidence established their authority to bind that party?
- Were a spouse, cosigner, guarantor, contractor, broker, or countersigner also
  required?
- Does any authorized representative satisfy the rule, must everyone agree, or
  is signing ordered?
- What happens when terms change after the first assent but before the last?
- Can an expired, revoked, or superseded link still accept an assent?
- What happens when a provider retries the same webhook or contradicts an
  earlier event?
- Can paper, in-person, imported, and hosted-native evidence coexist without
  pretending they prove the same ceremony?
- What exactly is amended, terminated, revoked, or superseded after agreement?
- Which downstream work may begin, and how is replay prevented from creating it
  twice?

These are not renderer details. They determine whether the application can say
what was agreed, by whom, and why it believes that claim.

## Candidate vocabulary

These names describe the problem. They do not freeze a future class or table
API.

| Concept | Meaning |
| --- | --- |
| **Document** | Stable business identity: a proposal, SOW, buyer agreement, change order, grant agreement, or other domain-owned instrument. |
| **Document revision** | One immutable set of structured terms and artifacts. Agreement always references a revision, never mutable “current content.” |
| **Issuance** | Presentation of one revision to a snapshotted party roster under one acceptance rule. |
| **Party** | The natural person or legal entity intended to be bound. |
| **Actor/signatory** | The human performing an assent act, possibly for a party other than themselves. |
| **Agreement party** | The issuance-specific snapshot of party identity, role, requirement, order, and representation posture. |
| **Assent** | An attributed act agreeing to the exact revision. A typed name, external e-signature, or reviewed paper record is evidence for an assent. |
| **Acceptance rule** | The frozen rule that decides whether the required assent set is complete: all required, any authorized representative, ordered, or another bounded rule. |
| **Agreement** | The durable fact created when the acceptance rule is satisfied for the exact revision and party roster. |
| **Artifact/manifest** | The canonical structured manifest, rendered artifact, hashes, and renderer/version evidence needed to reproduce the agreed terms. |
| **Delivery/access record** | Evidence that a capability was issued, delivered, opened, rotated, revoked, or expired. Delivery is not assent. |

The distinction between party and actor is foundational. A corporation may be
the party while an officer is the signatory. A homeowner may sign personally.
A guardian, power-of-attorney holder, or other representative may act for
someone else only when the host application recognizes that authority. The
kernel must record the distinction; it cannot invent the authority.

## The canonical flow

```text
Host-owned document
      |
      v
Exact immutable revision and artifact manifest
      |
      v
Issuance + snapshotted parties + acceptance rule
      |
      v
Controlled delivery/access capabilities
      |
      v
Attributed assents against the exact revision
      |
      v
Quorum evaluation
      |
      +---- pending ----> wait for another required assent
      |
      +---- satisfied --> create Agreement once
                              |
                              v
                    host-owned consequences
```

The host application composes the document, declares the parties and their
authority, selects the acceptance rule, and owns every downstream consequence.
The kernel freezes and preserves the exact revision, roster, assent evidence,
and agreement result.

Provider badges and webhooks are inputs to reconciliation, not independent
agreement truth. A provider saying “complete” cannot cure a mismatched revision,
missing party, invalid authority, revoked issuance, or failed host invariant.

## Cross-domain application

The grammar stays stable while the document, parties, rule, and consequence
change.

| Domain | Host-owned document | Typical parties | Possible consequence of agreement |
| --- | --- | --- | --- |
| Home services | Proposal, selected scope, change order | Contractor entity, homeowner, cosigner, contractor when required | Accepted work, material, and invoice-schedule creation |
| Real estate | Buyer representation, listing agreement, lease, addendum | Brokerage, buyers, sellers, landlord, tenants | Representation, duties, access, or transaction rights become operative |
| Property management | Management agreement, vendor agreement, lease addendum, work authorization | Manager, owner, vendor, landlord, tenant | Management, dispatch, or spend authority becomes operative |
| Hospitality and retail | Catering/event order, supplier contract, lease, equipment/service agreement | Operating entity, customer, supplier, landlord | Event commitment, purchasing terms, or service obligations begin |
| Nonprofit | Grant, sponsorship, partnership MOU, restricted-fund agreement, waiver | Foundation, grantee, sponsor, partner, participant | Restrictions, deliverables, reporting, or participation terms begin |
| Funding and finance | Funding agreement, brokerage agreement, guaranty, disclosure package, amendment | Merchant, funder, broker when actually a party, guarantors | Funding and repayment obligations may become operative after other conditions |
| Professional services | Master agreement, SOW, change order, license, handoff acceptance | Service entity, client entity, authorized representatives | Mobilization, billing, scope, license, ownership, or support terms begin |
| Employment and people operations | Offer, employment agreement, NDA, separation agreement | Employer entity, worker, authorized representatives | Employment or post-employment obligations begin |

The table describes candidate uses, not a claim that every listed document is
binding, appropriate, or governed by the same law. Each host owns that semantic
and legal determination.

## What must remain outside the kernel

The easiest way to destroy this abstraction is to turn it into a universal
business-document system.

| Record or act | Why it is different |
| --- | --- |
| **Proposal or quote** | An offer document until its required parties assent. It may expire without ever producing an agreement. |
| **Invoice/receivable** | Usually one party's payment claim under an existing agreement. Payment or dispute belongs to a money ledger. |
| **Vendor invoice/payable** | A source claim received from a vendor, not a new bilateral agreement. |
| **Payment** | A money event that may satisfy an obligation; it is not assent to arbitrary new terms. |
| **Receipt** | Evidence of a payment or delivery event, not an agreement. |
| **Authorization/approval** | Often a unilateral act under existing authority rather than a new agreement between parties. |
| **Acknowledgement** | Evidence of receipt or awareness; it may deliberately stop short of consent. |
| **Consent/waiver** | May reuse assent evidence mechanics, but its authority, revocability, and legal meaning can differ from a bilateral agreement. |
| **Ordinary retail sale** | Order, payment, and receipt records usually express the transaction without a separate formal agreement ceremony. |

Shared evidence mechanics do not make these records one domain. An application
may reuse a secure capability page or attributed-act component without
representing every click as an Agreement.

## Rails-shaped record model

The model should prefer explicit records over a document status flag:

```text
Document
  `-- has_many DocumentRevisions

DocumentRevision
  `-- has_many Issuances

Issuance
  |-- has_many AgreementParties
  |-- has_many Assents, through AgreementParties
  |-- has_one Agreement
  |-- has_many Deliveries / AccessCapabilities
  |-- has_one Revocation, optional
  `-- belongs_to SupersedingIssuance, optional

Agreement
  |-- belongs_to Issuance
  |-- references the exact revision, roster, assent set, and manifest hashes
  |-- has_many Amendments
  `-- has_one Termination, optional
```

An issuance exists before agreement. An assent is a record, not a boolean. An
agreement comes into existence when quorum is satisfied. Termination,
revocation, and amendment are later attributed records or relationships, not
destructive edits to the original accepted revision.

Two integration shapes remain open:

1. **Full engine ownership:** the engine stores Document and DocumentRevision
   records as well as execution records.
2. **Small execution kernel:** the host owns its Proposal, BuyerAgreement, SOW,
   or other document model; the kernel snapshots one immutable revision and
   owns only issuance, parties, assents, agreement, and integrity evidence.

Current evidence favors the smaller kernel. Domain authoring varies much more
than agreement execution, and a Rails engine should not force roofing line
items, real-estate compensation, financing disclosures, and service scope into
one content model.

## Host and kernel ownership

| Future kernel may own | Host Rails application must own |
| --- | --- |
| Revision/manifest immutability and hashes | Domain authoring, calculations, selections, terms, and validation |
| Issuance lifecycle and capability integrity | Which document is eligible to issue |
| Party-roster snapshots and acceptance-rule evaluation | Canonical party identity and who may bind each party |
| Assent attribution, idempotency, and evidence method | Whether a ceremony is appropriate and legally approved |
| Agreement creation and integrity proof | Domain effects triggered by agreement |
| Provider reconciliation contract | Provider selection, accounts, operational response, and retention policy |
| Generic lifecycle events/hooks | Domain-specific audit, analytics, notices, and compensation |

The kernel may say, “the frozen rule was satisfied by these recorded assents to
this exact revision.” It may not say, “this person had legal authority,” “this
ceremony is enforceable in every jurisdiction,” or “these business terms are
valid.” Those remain host and operator responsibilities, informed by counsel.

## Hard invariants

A credible implementation needs at least these invariants:

1. **Exact revision:** every assent and agreement references one immutable
   revision and canonical content/artifact digest.
2. **Frozen roster:** required parties, roles, order, and acceptance rule cannot
   change after issuance. Correction creates a new issuance.
3. **Party/actor separation:** the record distinguishes who is bound from the
   human who acted and records claimed representative capacity.
4. **No invented authority:** only a host-approved authority decision allows a
   representative to assent for another party.
5. **Attributed evidence:** assent records the party, actor, method, occurrence,
   evidence reference, revision, and issuance.
6. **Quorum from records:** agreement derives from the frozen rule and durable
   assent rows, not a mutable `signed` status or provider badge.
7. **Create once:** concurrent final assents and provider replays create at most
   one Agreement and one downstream agreement event.
8. **Safe replay:** an identical replay returns current truth; conflicting
   identity, revision, provider, or evidence fails visibly.
9. **Stale means closed:** expired, revoked, and superseded issuances cannot
   accept a new assent.
10. **No silent content mutation:** renderer, asset, attachment, template, and
    structured-term changes produce a new digest/revision.
11. **Evidence classes remain honest:** imported, paper, in-person,
    hosted-native, and provider evidence keep their actual provenance.
12. **Delivery is not assent:** sending, opening, previewing, or a crawler GET
    never creates an assent.
13. **Downstream idempotency:** the host consumes one agreement identity/hash;
    replay cannot duplicate work, invoices, access, or funding actions.
14. **Append-only correction:** amendments, revocations, terminations, refunds,
    and unwind procedures preserve the original history.
15. **Tenant and authorization scope:** every read/write is scoped through the
    host's ownership and authority boundary.
16. **No ambient AI assent:** an authenticated tool caller may draft, issue, or
    inspect only when host policy permits; it does not gain authority to agree
    for a party merely because it can call a tool.

## Assent mechanisms and adapters

Signing is a mechanism beneath agreement truth. Candidate mechanisms include:

- a native hosted typed-name/checkbox ceremony;
- an external e-sign provider;
- a reviewed paper artifact and attributed operator declaration;
- an in-person ceremony; and
- a bounded historical import.

A future provider adapter should normalize only provider mechanics: request,
cancel, fetch/reconcile, verified event receipt, and evidence/artifact
retrieval. It should not decide party authority, quorum, document eligibility,
or downstream business effects.

No public adapter API has earned its shape yet. In particular, the system has
not demonstrated enough independent providers to publish an Active Job-style
registry. A provider seam can remain private inside the first extraction until
real integrations expose the common verbs and failure modes.

## Access, delivery, and privacy perimeter

Agreement pages are unusually sensitive public surfaces. A reusable system
must make its perimeter explicit:

- store capability-token digests rather than raw tokens when feasible;
- bind capabilities to purpose, issuance, revision, and intended participant;
- support expiration, rotation, and revocation without changing accepted
  content;
- prevent referrer leakage, indexing, and unnecessary third-party assets;
- distinguish human evidence-grade views from operators, HEAD requests,
  crawlers, link previewers, and deployment checks;
- throttle reads and assent attempts;
- verify provider webhook signatures, timestamps, account, document, party,
  and revision identity before reconciliation;
- treat IP addresses, user-agent strings, names, emails, artifacts, and audit
  evidence as sensitive retained data;
- keep secrets, document bodies, arguments, results, and raw exceptions out of
  generic framework telemetry; and
- fail closed when tenant scope, party identity, representative authority,
  revision integrity, or provider reconciliation is ambiguous.

The correct CSRF, authentication, identity-proofing, retention, and disclosure
posture depends on the chosen ceremony and host risk. The library must document
what it proves and what it does not; it must not turn a technical audit bundle
into a universal enforceability claim.

## Agreement lifecycle after acceptance

Agreement is not the end of the problem.

### Amendment

An amendment is a new document revision and new issuance that identifies the
agreement it changes. It carries its own parties, acceptance rule, assents, and
artifact. When accepted, the host computes or stores the explicit delta. The
original agreement remains unchanged.

### Supersession

An unaccepted issuance may be superseded by a newer issuance. Its capability
must stop accepting assent. Existing delivery/view history remains evidence of
what occurred.

### Revocation and expiry

These close an unaccepted issuance. They do not erase it. Expiry may be derived
from a frozen deadline; revocation is an attributed record with authority and
reason.

### Termination

Termination affects an existing agreement according to domain-owned terms. It
does not rewrite the historical agreement or delete prior obligations and
events.

### Unwind and compensation

Voiding or terminating an accepted agreement is not synonymous with refunding
money, cancelling work, removing access, reversing inventory, or notifying
providers. Those are separate host-owned processes with explicit authority,
idempotency, and partial-failure handling.

## Product surfaces this kernel could enable

The small kernel supports a surprisingly broad product surface without owning
each domain's content:

### Operator work

- reusable template/revision publication around host-authored documents;
- issue/read/revoke/supersede worklists;
- missing-party and pending-assent queues;
- representative-capacity and authority review;
- resend/rotate/recover delivery operations;
- paper/import evidence review;
- amendment and renewal calendars;
- immutable acceptance bundles for support, audit, migration, and handoff; and
- provider exception/reconciliation worklists.

### Customer or counterparty experience

- mobile-first, no-training document review;
- exact signer role and represented party;
- clear pending/completed/expired/revoked/superseded states;
- safe re-entry and idempotent re-submit;
- multi-party progress without leaking other parties' private data;
- downloadable accepted artifacts; and
- correction flows that never ask someone to accept silently changed terms.

### AI-assisted work

AI may help draft domain-owned content, compare revisions, explain terms,
identify a missing required party, prepare an issuance, summarize pending work,
or propose follow-up. It may expose those operations through authenticated MCP
tools with host authorization and preview/confirmation.

AI must not infer representative authority, fabricate an assent, sign for a
party, convert an acknowledgement into agreement, or treat delivery/provider
status as acceptance. Human and legal-entity authority remains explicit.

### Analytics

- time from issue to first view, first assent, and agreement;
- abandonment by revision, delivery channel, or party role;
- provider failure/replay/reconciliation rates;
- amendment, expiry, supersession, and termination rates; and
- operational workload for pending-party and exception queues.

These measurements describe the agreement process. They do not by themselves
prove revenue, cash, legal enforceability, customer satisfaction, or downstream
completion.

## Hitch integration boundary

Hitch can make agreement capabilities available to authenticated MCP users
without learning agreement semantics.

Plausible host tools include:

- list/read pending issuances and agreements;
- preview and confirm issuance;
- resend or rotate an access capability;
- preview and confirm revocation or supersession;
- record reviewed paper/import evidence under explicit operator authority; and
- inspect provider reconciliation exceptions.

A general-purpose `sign` or `assent_for_party` AI tool should not be provided by
default. Tool availability and argument-aware authorization remain host policy.
The agreement kernel owns record integrity; Hitch owns authenticated tool
exposure; the host owns whether a principal may perform the business action.

## Interaction model

The companion Lattice schema models the agreement-creation gate across:

- exact versus mutable/mismatched revision;
- complete versus incomplete party roster;
- intended person, authorized representative, or unknown/unauthorized actor;
- hosted-native, external-provider, or paper/in-person evidence;
- new, replayed, or conflicting evidence;
- open, expired/revoked, or superseded issuance; and
- pending, satisfied, or invalid-roster quorum.

The schema leaves 972 valid exhaustive combinations. Lattice reduces them to 15
deterministic pairwise review scenarios at 100% pair coverage with seed 42. It
forces positive agreement creation through all three mechanism classes, a
valid partial-quorum path, and an idempotent replay path.

Artifacts:

- [`agreement_creation_gate.lattice.json`](agreement_creation_gate.lattice.json)
- [`agreement_creation_gate_scenarios.json`](agreement_creation_gate_scenarios.json)

The interpretation oracle is:

1. Create an Agreement only when revision integrity is exact, the roster is
   complete, the actor is the intended person or an authorized representative,
   evidence is new and valid, the issuance is open, and quorum is satisfied.
2. With the same valid gate but pending quorum, record the assent and remain
   pending.
3. An exact replay by the same intended person or authorized representative,
   against the same immutable revision and complete roster, creates no new
   assent, agreement, or downstream effect and returns current truth. A claimed
   replay with mismatched identity or evidence is conflicting evidence instead.
4. Mutable/mismatched content, incomplete roster, unauthorized/unknown actor,
   conflicting evidence, or stale issuance creates no assent or agreement.
5. `invalid_roster` is not a pending business state; it is a refusal requiring
   corrected issuance.

These rows are review scenarios today. They should become shared conformance
fixtures only after the intended behavior is accepted and an implementation
exists.

## Current evidence and extraction maturity

The idea is stronger than a purely speculative abstraction, but weaker than a
public-gem contract.

Current evidence includes:

- one working, tested commercial-proposal implementation with immutable-on-
  issue line items, capability access, delivery/view evidence, single-signer
  acceptance, expiry, replay safety, supersession, voiding, and imports; and
- one separately developed real-estate buyer-agreement implementation with
  snapshotted terms, multiple decision-makers, per-party signature rows,
  quorum, and activation after execution.

The two implementations reveal a genuine common operation and useful
variation. They do not yet prove a stable public API:

- one is materially more hardened than the other;
- neither fully implements canonical content manifests, immutable artifact
  bundles, every party/representative distinction, and every mechanism above;
- external provider adapters do not have independent convergence evidence;
- other domain mappings are needs/hypotheses rather than completed consumers;
  and
- there is not yet a second independent paid-client adoption of an extracted
  kernel.

The Rails-purist classification is therefore:

> Ready for a private extraction and conformance spike; not ready for a stable
> public gem or Hitch-core commitment.

## Extraction sequence

1. **Freeze this problem contract.** Review vocabulary, ownership, negative
   space, invariants, and the Lattice oracle without designing a public API.
2. **Harden the first implementation.** Add exact content/revision manifests,
   party snapshots, agreement-as-record, artifact integrity, and the missing
   multi-party cases where the product actually needs them.
3. **Build a private small kernel.** Extract only revision/issuance/party/
   assent/agreement mechanics. Keep domain authoring and downstream effects in
   the host.
4. **Port the independent implementation.** Reconcile its multi-party and
   activation semantics through the same conformance fixtures. Differences
   revise the private contract rather than becoming flags automatically.
5. **Use it for a real second client/domain.** Prove installation, migration,
   customization, operator UX, and support burden outside the design roots.
6. **Decide product shape.** Only then choose in-repo module, private gem,
   mountable engine, companion gem, or public project and name its supported
   Rails/database/provider matrix.
7. **Publish only an earned API.** Document exact ownership, adapters,
   migrations, removal, security posture, legal boundary, and conformance
   evidence.

Copying or maintaining two local versions during steps 1–3 is not failure. The
differences are the evidence needed to discover the real abstraction.

## Open questions

### Domain and identity

- Does the kernel own a canonical Party record, or only immutable party
  snapshots sourced from host models?
- How does the host prove and revoke representative authority?
- Is Agreement created only at quorum, or is there a differently named pending
  aggregate before quorum?
- Are acknowledgement and consent separate sibling kernels or consumers of a
  smaller attributed-act primitive?

### Content and artifacts

- Does the kernel store canonical structured content, a host-produced manifest,
  rendered bytes, or all three?
- Which renderer and asset metadata must be frozen to reproduce what was seen?
- Can a large attachment set be content-addressed without copying every blob?
- What constitutes a semantically new revision versus a presentation-only
  change?

### Parties and quorum

- Which bounded acceptance rules cover real consumers without creating a rules
  language?
- How are ordered signing, countersignature, optional acknowledgers, substitute
  representatives, and declined signatures represented?
- What happens when a party dies, dissolves, changes representative, or loses
  authority while an issuance is pending?

### Providers and evidence

- What common provider operations survive native, external, paper, and import
  implementations?
- Which provider facts are authoritative, which are hints, and which require a
  pull reconciliation?
- How are provider migrations handled without changing historical evidence?
- What retention/deletion policy applies to identity and signing evidence?

### Product and packaging

- Is the smallest useful product a model kernel, a mounted engine with public
  pages, or a set of conformance fixtures and generators?
- Which UI must be supplied versus host-owned?
- Which hooks are public and which lifecycle events are merely internal?
- How does uninstall/removal preserve accepted agreements and artifacts?
- Does the project belong beside Hitch as a companion, or in a separate domain
  repository with optional Hitch integration?

### Authority and legal posture

- Which actions may an authenticated operator, customer, automated agent, or
  external provider perform?
- Which actions require preview/confirmation or cannot be delegated to AI?
- Which ceremonies and content require jurisdiction- and domain-specific legal
  review before production use?
- How does documentation state technical guarantees without implying universal
  enforceability?

## Non-goals for the exploration

- Naming the gem or promising that one will exist.
- Moving proposal, invoice, payment, CRM, inventory, or workflow domain logic
  into Hitch.
- Designing a generic rich-text CMS or contract-language engine.
- Replacing legal advice, identity verification, payment ledgers, accounting,
  or provider compliance programs.
- Treating every approval, acknowledgement, authorization, click, or document
  as an agreement.
- Publishing provider adapters before multiple real implementations expose a
  stable operation.
- Generalizing private-client behavior before a second independent use proves
  the boundary.

## Decision record

The current decision is deliberately narrow:

1. Preserve the problem space and interaction model.
2. Treat “document + agreeing parties + assent to an exact revision” as the
   leading extraction thesis.
3. Keep it outside Hitch core unless future evidence changes the ownership
   boundary.
4. Permit a private extraction spike after the active Hitch MCP roadmap work is
   complete or separately staffed.
5. Do not call the thesis a reusable public module until two implementations
   pass one conformance contract and a real second-client adoption validates
   the package boundary.
