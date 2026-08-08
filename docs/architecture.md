# BeaconAgentKit Architecture

BeaconAgentKit separates reusable Agent mechanics from app-specific domain logic. A deployment may replace the model provider, registry store, retriever, checkpoint store, transport, device handlers, or renderers independently while preserving versioned protocol boundaries.

## Targets

- `BeaconAgentCore`: Foundation-only event, run, thread, tool run, card envelope, timeline reducer, policy, JSON payload, and redaction primitives.
- `BeaconAgentSwiftUI`: generic SwiftUI timeline, card stack, and tool run views.
- `BeaconAgentAGUI`: AG-UI-inspired event decoding and adapter entry points.
- `BeaconAgentA2UI`: validated incremental surface state, patches, and action envelopes.
- `BeaconAgentDevice`: trusted host authorization and device-local tool execution.
- `BeaconAgentMCP`: MCP and MCP Apps translation through ordinary capability contracts.
- `BeaconAgentAppleEvents`: Codable Apple-platform event model families without concrete framework adapters.
- `python/beacon_agent_runtime`: provider-neutral reference control plane, registry, router, Agent loop, policy, checkpoints, knowledge, observability, and evaluation.

## Module Boundary

BeaconAgentKit owns generic Agent control and interaction state:

```text
signed registry snapshot -> strict effective registry -> staged route
  -> bounded model/tool/observation loop -> ordered AG-UI events
  -> validated A2UI surface / device interrupt -> host decision and observation
```

Apps own domain capability packs, identity, permissions, local records, product prompts, persistence, record mutation, and product-specific renderers. The control plane can enable or disable a manifest, but the effective registry includes a capability only when the host also advertises a compatible implementation and trusted authorization/policy allow it.

For example, a food, finance, learning, or productivity app can wrap a pending review result as a generic `BeaconCardEnvelope`, but the actual app record model, validation rules, and mutation side effects stay in that app.

## Data Flow

1. The control plane publishes a signed, expiring registry snapshot.
2. The host intersects server state with advertised tools, schema compatibility, trusted scopes, and local policy.
3. Staged routing uses pending workflow and structured context before retrieval and constrained reranking.
4. The bounded runtime alternates model actions, validated tool observations, approvals, and checkpoints.
5. Device tools interrupt the server run. The host validates trusted identity, permission, confirmation, expiry, schema, and idempotency before local execution.
6. AG-UI events stream safe activity, tool status, text deltas, and A2UI surface patches with stable IDs.
7. SwiftUI or host renderers project that stream into native state. Unknown surfaces fall back safely.
8. A confirmed write returns a local receipt; retry replays the receipt and local read-back verifies the result.

## Foundation-Only Core

`BeaconAgentCore` must remain usable without linking SwiftUI, UIKit, HealthKit, ActivityKit, CoreLocation, UserNotifications, or WatchConnectivity. Apple and SwiftUI integrations live in separate targets so server-side tests, command-line tools, and privacy-sensitive apps can adopt the core safely.

## Knowledge and evaluation

Knowledge packs are separately versioned artifacts with source provenance, locale, reuse status, review expiry, citation policy, safety exclusions, and evaluation datasets. Evidence-marked answers must cite a passage from the current retrieval. Evaluation reports measure route recall, capability precision, unnecessary tool calls, clarification correctness, policy violations, completion, surface fallback, and task success.

## Replaceable interfaces

The Python runtime depends on `ModelProvider`, `ToolDispatcher`, `CheckpointStore`, `PolicyEngine`, `EventSink`, `RegistryProvider`, `CapabilityRetriever`, and `CapabilityReranker` protocols. Swift hosts depend on capability advertisements, device handlers, event decoders, surface stores, and renderer catalogs. Product integrations should implement these boundaries instead of forking core logic.

## v0.2 Non-Goals

- No bundled model-provider SDK.
- No HealthKit, ActivityKit, WatchConnectivity, or App Intents adapters.
- No app-specific nutrition, supplement, training, or posture models.
- No WebView chat UI.
