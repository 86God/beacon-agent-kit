# BeaconAgentKit v0.2 Platform Design

Status: Proposed for implementation review  
Date: 2026-08-08  
Canonical repository: `https://github.com/86God/beacon-agent-kit`

## 1. Decision

BeaconAgentKit v0.2 evolves from an Apple-client event package into a protocol-first,
domain-neutral Agent platform. JianHao is its first production host, not a framework
module.

The dependency direction is permanent:

```text
BeaconAgentKit never imports JianHao.
JianHao imports BeaconAgentKit and implements framework ports.
```

The framework owns reusable Agent mechanics, protocols, policy primitives, capability
discovery, streaming state, and generic UI. A host application owns its domain data,
domain tools, domain knowledge, branded surfaces, permissions, and side effects.

## 2. Why this approach

Three repository shapes were considered.

### A. Keep the Agent implementation inside JianHao

This is fastest for a single feature, but hard-codes health models into routing,
runtime, and UI. Reuse requires copying code and makes framework testing dependent on
the app. Rejected.

### B. Publish only a client UI SDK

This preserves the current v0.1 boundary, but leaves capability registration, routing,
the Agent loop, policy, and control-plane logic embedded in each product. It does not
solve replaceability or administration. Rejected as the final architecture.

### C. Protocol-first platform with host capability packs

The repository contains language-neutral schemas, reference runtime packages, client
SDKs, protocol adapters, generic UI, and conformance tests. Products integrate through
capability packs and host adapters. Selected because it keeps business ownership local
while making the Agent system portable across mobile, web, desktop, and server hosts.

## 3. Goals

- Provide a real iterative Agent loop: model, tool request, observation, next model
  decision, and final response.
- Register Tool, Skill, Workflow, Knowledge Pack, and Surface through one versioned
  capability contract.
- Let an administrator enable or disable capabilities without shipping a new app.
- Let a host advertise which local executors, renderers, and protocol versions are
  installed.
- Route each user request only across the capabilities that are enabled, installed,
  compatible, authorized, and policy-allowed.
- Execute privacy-sensitive tools on the device while allowing a remote model to
  orchestrate them.
- Stream text, activity, tools, approvals, and structured surfaces as they are produced.
- Keep model providers, retrieval engines, vector stores, transports, and renderers
  replaceable.
- Provide deterministic replay, conformance tests, policy receipts, and evaluation
  hooks.
- Preserve the v0.1 Swift package APIs while introducing v0.2 modules incrementally.

## 4. Non-goals for v0.2

- Hosting a public multi-tenant SaaS control plane.
- Building grey rollout, billing, marketplace, or third-party capability installation.
- Shipping a general web or desktop application.
- Moving JianHao health records, HealthKit access, or mutation logic to the server.
- Open-sourcing licensed fitness knowledge or JianHao product assets.
- Supporting arbitrary executable code downloaded from capability manifests.
- Exposing raw model chain-of-thought. User-visible reasoning is limited to safe activity
  summaries and tool lifecycle events.

## 5. System boundary

```text
Host applications
  JianHao iOS / future web or desktop apps
      |
      | capability advertisement + AG-UI events + A2UI actions
      v
BeaconAgentKit platform
  Protocol | Runtime | Registry | Router | Policy | UI | MCP adapters
      |
      | provider ports
      v
Model APIs | storage | vector search | transports | telemetry
```

### BeaconAgentKit owns

- Run, thread, message, activity, tool, approval, state, and surface protocols.
- Capability manifests and effective-registry calculation.
- Candidate retrieval, reranking interfaces, and routing decisions.
- Agent run loop, limits, interrupts, resume, cancel, and checkpoints.
- Generic permission, risk, confirmation, idempotency, audit, and redaction models.
- AG-UI transport/event adaptation.
- A2UI validation, state reduction, action envelopes, and component-catalog interfaces.
- MCP tool/resource/MCP Apps adapters.
- Progressive Markdown parsing and generic Agent timeline presentation.
- Provider interfaces and deterministic test providers.
- Protocol conformance, replay fixtures, and evaluation harnesses.
- Control-plane APIs for capability publication, version selection, and enable/disable.

### Host applications own

- Domain models, persistence, account scope, and record ownership.
- Domain tool implementations and final side effects.
- Device APIs such as HealthKit, WatchConnectivity, camera, and local databases.
- Product knowledge, licensed content, prompts, and domain validation.
- Domain-specific card schemas and renderers.
- Product theme, navigation, analytics consent, and accessibility policy.
- Secrets, deployment configuration, synchronization, and backup.

## 6. Repository layout

The existing Swift package remains at the repository root for source compatibility.
New platform areas are added without moving v0.1 targets in the first milestone.

```text
beacon-agent-kit/
├── Package.swift
├── Sources/
│   ├── BeaconAgentCore/
│   ├── BeaconAgentSwiftUI/
│   ├── BeaconAgentAGUI/
│   ├── BeaconAgentA2UI/
│   ├── BeaconAgentMCP/
│   └── BeaconAgentAppleEvents/
├── specs/
│   ├── capability-manifest.schema.json
│   ├── agent-event.schema.json
│   ├── run-input.schema.json
│   ├── route-decision.schema.json
│   ├── approval-request.schema.json
│   └── execution-receipt.schema.json
├── python/
│   ├── pyproject.toml
│   ├── beacon_agent_runtime/
│   └── tests/
├── control-plane/
│   ├── openapi.yaml
│   └── reference/
├── conformance/
│   ├── fixtures/
│   └── runners/
├── examples/
│   ├── local-tasks/
│   └── device-tool-loop/
└── docs/
```

TypeScript SDK and React renderers are a post-v0.2 consumer. The language-neutral JSON
schemas are designed so that those packages can be added without changing protocol
semantics.

## 7. Capability model

Every available function is represented by one `CapabilityManifest`.

### Capability kinds

- `tool`: one bounded read or action with typed input and output.
- `skill`: reusable instructions, examples, and optional knowledge references.
- `workflow`: a resumable multi-step graph with declared tool dependencies.
- `knowledge`: a versioned retrieval corpus with provenance and citation policy.
- `surface`: a renderer contract and action vocabulary for structured UI.

### Required manifest fields

```json
{
  "id": "training.plan.draft",
  "version": "1.0.0",
  "kind": "workflow",
  "title": "Draft a training plan",
  "description": "Builds a reversible plan draft for a requested date.",
  "intentExamples": ["Arrange shoulder training tomorrow"],
  "inputSchema": {"type": "object"},
  "outputSchema": {"type": "object"},
  "executionLocation": "device",
  "risk": "reversible_draft",
  "requiredScopes": ["training.read", "training.draft.write"],
  "confirmation": "before_commit",
  "idempotency": "required",
  "dependencies": [
    "training.context.read@^1",
    "exercise.candidates.search@^1"
  ],
  "surface": "training.plan.draft@^1",
  "tags": ["training", "plan", "shoulder"],
  "fallback": "text_summary"
}
```

Manifests describe capabilities; they never contain executable code, secrets, user
identifiers, or health data.

### Effective registry

The model can see only this intersection:

```text
server-enabled capabilities
∩ host-advertised capabilities
∩ protocol-compatible versions
∩ user-authorized scopes
∩ current policy decision
```

This effective registry is frozen for one Agent step. A later step may receive a newer
registry snapshot only after an explicit refresh, preventing an administrator change
from altering a tool call midway through validation or execution.

## 8. Control plane

The v0.2 control plane has four responsibilities:

1. Publish validated capability manifests.
2. Enable or disable a capability globally for one product environment.
3. Select an allowed version range.
4. Return a signed registry snapshot with revision and expiry.

The first release supports `development`, `staging`, and `production` environments.
It does not implement per-user rollout. Runtime services fail closed when a registry
snapshot is expired and cannot be refreshed, except for capabilities explicitly marked
as offline-safe by the host.

The administrator cannot grant device permission or bypass confirmation. Control-plane
enablement means a capability may be considered; host authorization remains mandatory.

## 9. Intent and routing pipeline

Routing is not a single free-form classification call. It is a staged decision:

1. **Deterministic context extraction** resolves conversation mode, explicit dates,
   active approval, attachment type, and an in-progress workflow.
2. **Capability retrieval** searches only the effective registry using lexical tags and
   semantic retrieval.
3. **Model reranking** ranks a small candidate set and may select a specialist Agent or
   direct workflow.
4. **Policy filtering** removes candidates that are not authorized for the current
   identity, device, data scope, or risk context.
5. **Planner decision** chooses a tool, asks a consequential clarification, creates a
   reversible draft, or answers directly.
6. **Kernel authorization** validates every concrete tool call again immediately before
   execution.

Routing output is a typed `RouteDecision` containing candidate IDs, selected IDs,
confidence, reasons safe for audit, required clarification, and registry revision.
Model prose is never used as the executable routing decision.

The router asks for clarification only when ambiguity changes a consequential action,
including date, target record, overwrite behavior, injury or pain constraints, or final
write scope. Read-only context lookup and reversible drafts can proceed without an
extra interruption.

## 10. Agent runtime

The runtime executes a bounded loop:

```text
start run
  -> resolve effective capabilities
  -> call model with selected capability schemas
  -> emit text/activity/tool/surface events
  -> if tool requested:
       authorize call
       dispatch to server or host device
       receive typed observation
       append minimal observation
       checkpoint
       continue loop
  -> if approval required:
       emit interrupt and persist checkpoint
  -> otherwise finish or fail
```

Default limits are configurable per deployment and have safe framework defaults:

- Maximum 12 Agent steps per run.
- Maximum 8 tool calls per run.
- Maximum 3 recoverable retries across the run.
- Maximum one pending consequential approval per run.
- Maximum observation size of 64 KiB after redaction.

The runtime distinguishes model failure, transport failure, tool rejection, invalid
arguments, permission denial, approval expiry, capability removal, and host disconnect.
Each failure maps to a stable error code and recovery policy.

## 11. Device-local tool execution

Privacy-sensitive reads and writes use a remote-orchestrated, local-execution handshake:

1. The server emits a typed tool request with `runId`, `toolCallId`, schema version,
   registry revision, requested scopes, and idempotency key.
2. The app verifies account/device scope, installed executor version, local permission,
   policy, and confirmation requirements.
3. The app executes against local stores.
4. The app redacts the result and returns the minimum structured observation required
   for the next Agent decision.
5. The server incorporates that observation and continues the run.

The model cannot provide user ID, device ID, database path, account scope, or permission
state as tool arguments. The host injects those values from trusted session context.

Writes are draft-first. A model may create or update a reversible draft without final
confirmation, but committing a health, nutrition, training, or profile record requires
the host-defined confirmation policy. Every commit returns an execution receipt and is
idempotent.

## 12. Streaming and frontend protocol

AG-UI is the primary run and interaction event transport. BeaconAgentKit maps compatible
standard events directly and uses documented extension events only when the standard
does not cover a required semantic.

Required event families:

- Run lifecycle: started, finished, error, interrupt.
- Step and activity: started, delta/snapshot, finished.
- Text: start, delta, end.
- Tool call: start, argument delta, end, result.
- State: snapshot and RFC 6902 delta.
- Surface: create, patch, complete, error.
- Approval: requested, resolved, expired.
- Receipt: execution committed or rejected.

Text and surfaces are independent siblings in the timeline. The model does not emit a
Markdown table when a registered domain surface is selected. It emits a surface payload
whose state can be incrementally patched while the rest of the response continues.

Progressive Markdown rendering parses stable completed blocks during streaming and keeps
only the incomplete trailing block in plain form. Finalization must not replace the
message with a visually different second rendering.

A2UI is used for declarative, native structured surfaces. The framework validates
component topology, catalog membership, data paths, action vocabulary, payload size,
and patch sequence. Arbitrary HTML, JavaScript, and remote executable UI are rejected.

## 13. UI component ownership

### Framework catalog

- Agent message and progressive Markdown.
- Activity row and expandable tool trace.
- Generic metric, list, table, notice, error, retry, approval, and receipt surfaces.
- Streaming skeleton and partial-state presentation.
- Unknown-surface fallback.
- Theme tokens, accessibility semantics, Dynamic Type behavior, and Reduce Motion hooks.

### Host catalog

- Training-plan draft and exercise replacement.
- Meal review and nutrition correction.
- Sleep and recovery summaries.
- Product-branded empty states, navigation, and domain actions.

The host registers renderers by versioned surface ID. The framework reducer owns state
and lifecycle; the host renderer owns domain presentation and maps user actions back to
typed action envelopes.

## 14. Knowledge packs

The framework provides `KnowledgeManifest`, retrieval, citation, provenance, version,
and evaluation interfaces. It does not bundle JianHao professional fitness content.

A knowledge pack declares:

- Corpus ID and semantic version.
- Supported locale and domain.
- Source provenance and commercial-use status.
- Retrieval adapter and chunk schema.
- Citation requirements.
- Safety disclaimers and excluded advice categories.
- Evaluation dataset version.

JianHao stores its private-coach knowledge pack in the product repository or a separate
licensed-content repository. Retrieved passages are sent to the model only when the
router selects the pack and policy permits the query. Answers preserve source IDs so the
app can show evidence and the evaluation harness can detect unsupported claims.

## 15. Security and privacy

- Capability manifests are validated and registry snapshots are signed.
- Tool arguments and outputs are schema-validated at every boundary.
- Identity and ownership come from trusted host context, never model arguments.
- Raw images, base64 data, API keys, access tokens, phone numbers, and full health record
  dumps are forbidden in display summaries and audit logs.
- Audit records contain IDs, versions, decisions, timings, redacted summaries, and
  receipts; they do not contain private reasoning or unrestricted tool output.
- The framework never downloads and executes capability code.
- Unknown capabilities, versions, tools, actions, and surface components fail closed.
- A host can delete local run artifacts and revoke a capability without requiring
  framework-specific data migration.

## 16. Failure and recovery

- A dropped stream reconnects with the last accepted sequence number and requests state
  snapshots before accepting further deltas.
- A duplicated event is ignored by event ID and sequence number.
- An invalid delta requests a fresh snapshot; it does not partially mutate visible state.
- A disconnected device tool call pauses the run and can resume from its checkpoint.
- A timed-out read may retry within budget; writes never retry without the same
  idempotency key.
- Capability removal before execution rejects the call. Removal after a committed local
  write does not invalidate its receipt.
- Unsupported surfaces fall back to a safe text summary and keep actions disabled.
- Model unavailability preserves the conversation and offers retry without replaying a
  completed tool write.

## 17. Observability and evaluation

Every run records structured, privacy-safe telemetry:

- Route candidates, selected capability IDs, versions, and registry revision.
- Step and tool duration, retry count, and terminal status.
- Approval requested/resolved/expired.
- Surface fallback and protocol validation failures.
- Token and provider cost metadata where available.
- Redacted execution receipts.

The conformance suite replays the same event fixture across Python and Swift reducers.
The evaluation suite measures intent recall, top-choice precision, unnecessary tool
calls, clarification quality, policy violations, tool completion, surface fallback,
and final task success. Product datasets remain outside the public framework and plug
into the same evaluator interface.

## 18. Reference vertical slice

The first integration proof is the JianHao request “安排一下明天练肩”.

Expected behavior:

1. Resolve “明天” using the device locale and calendar.
2. Retrieve the training-plan workflow and its dependencies from the effective registry.
3. Execute local reads for relevant profile, recent training, available equipment, and
   exercise candidates only when the planner requires them.
4. Emit visible activity events as each lookup begins and completes.
5. Stream a `training.plan.draft@1` surface with exercises, sets, repetitions, rest,
   reorder, replace, and edit actions.
6. Preserve the requested date in the draft and every subsequent action.
7. Ask for confirmation before final binding.
8. Commit through the JianHao device executor with an idempotency key.
9. Return an execution receipt and verify the plan by a local read.
10. Never query or mutate a server-side copy of the user’s training records.

This slice is successful only when replay tests, Python runtime tests, Swift protocol and
reducer tests, iOS simulator UI tests, and one physical-device local-write verification
all pass.

## 19. Delivery decomposition

This platform is too broad for one implementation batch. It is divided into independently
testable milestones:

1. **Protocol foundation:** JSON schemas, compatibility rules, fixtures, and Swift model
   alignment.
2. **Capability registry:** manifest validation, effective registry, signed snapshots,
   and administrator enable/disable.
3. **Agent runtime:** routing ports, bounded iterative loop, checkpoints, interrupts,
   receipts, and Python reference implementation.
4. **Device bridge:** Swift executor advertisement, local authorization, tool request and
   observation exchange, and idempotent commit.
5. **Streaming UI:** AG-UI adaptation, progressive Markdown, activity timeline, A2UI
   surface lifecycle, and host renderer catalog.
6. **JianHao training pack:** domain manifests, local handlers, training draft renderer,
   date-preserving confirmation, and end-to-end verification.
7. **Knowledge packs:** professional-content contracts, citation pipeline, provenance,
   and domain evaluation adapter.
8. **Open-source release:** documentation, examples, threat model, security policy,
   CI matrix, semantic versioning, and migration guide.

Each milestone must leave BeaconAgentKit and JianHao independently buildable. A public
API change is released in BeaconAgentKit before JianHao updates its dependency. No
milestone may require copying generic framework source into JianHao.

## 20. Versioning and compatibility

- Packages use semantic versioning.
- Wire schemas include their own `schemaVersion` independent of package releases.
- Capability and surface IDs are stable; breaking shapes require a new major version.
- Hosts advertise supported protocol, capability, and surface version ranges.
- Unknown optional fields are preserved or ignored according to each schema; unknown
  required semantics fail closed.
- v0.1 Swift event models remain available through v0.2 with adapters and deprecation
  notices only after equivalent protocol models ship.

## 21. Acceptance criteria

- BeaconAgentKit runtime and library source contains no JianHao source types, product
  strings, business rules, or user data.
- JianHao integrates through one app-owned adapter layer and capability packs.
- Disabling a capability in the control plane removes it from the effective registry.
- The model cannot invoke a disabled, absent, incompatible, unauthorized, or unapproved
  capability.
- A run can alternate between model and device tools more than once before completion.
- Tool and surface progress render before the final model response completes.
- The same streamed fixture produces equivalent terminal state in Python and Swift.
- Final local writes are confirmed, idempotent, auditable, and verifiable by local read.
- The “tomorrow shoulder training” slice writes tomorrow, never today.
- Framework tests, JianHao focused tests, simulator tests, and physical-device validation
  report exact results without treating simulator success as device evidence.

## 22. Reference standards

- AG-UI event model: <https://docs.ag-ui.com/concepts/events>
- A2UI v0.9 specification: <https://a2ui.org/specification/v0.9-a2ui/>
- Model Context Protocol tools: <https://modelcontextprotocol.io/specification/2025-06-18/server/tools>
- OpenAI Agents SDK run loop: <https://openai.github.io/openai-agents-python/running_agents/>
- OpenAI Agents SDK tools: <https://openai.github.io/openai-agents-python/tools/>
- Qwen-Agent: <https://github.com/QwenLM/Qwen-Agent>
