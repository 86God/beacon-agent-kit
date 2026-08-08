# BeaconAgentKit Status

## 2026-06-22 Phase 1

BeaconAgentKit v0.1 stabilization is focused on framework positioning, public API documentation, privacy-aware tests, and architecture docs.

Completed in this phase:

- Upgraded README positioning for a Swift-native AI interaction framework on Apple platforms.
- Added public API doc comments across core events, runs, threads, tool runs, cards, policy, redaction, AG-UI decoding, Apple event models, and generic SwiftUI views.
- Hardened tests for reducer tool failure upserts, nested JSON card payloads, image/base64 redaction, Apple motion events, and `BeaconAgentCore` import boundaries.
- Documented architecture, privacy policy model, AG-UI compatibility, Apple events roadmap, and demo app expectations.

Guardrails:

- `BeaconAgentCore` remains Foundation-only.
- BeaconAgentKit contains no app-specific food, supplement, workout, posture, prompt, or backend client models.
- Apple event support is model-only; no HealthKit, ActivityKit, Watch, notification, location, or App Intents adapters are implemented in v0.1.

## 2026-08-08 v0.2 implementation

Completed through Task 19:

- Framework-neutral capability registry, signed control-plane snapshots, staged routing, bounded resumable Agent loop, device execution contracts, AG-UI streaming, A2UI runtime, MCP Apps adapters, renderer catalog, observability, and package boundary checks.
- JianHao integration through a capability pack and device-local tool bridge for the streamed “安排一下明天练肩” workflow, including editable draft UI and tomorrow persistence.
- Provider-neutral knowledge contracts and JianHao private-coach knowledge pack v1. The product pack uses reviewed original summaries of authoritative sources, requires resolved citations for evidence, rejects unsupported medical advice, and admits when reviewed evidence is missing.

Task 20 also completed:

- Deterministic evaluation reports now measure route recall, capability precision, unnecessary tool calls, clarification correctness, policy violations, completion correctness, surface fallback, and task success.
- The repository includes a v0.2 threat model, security policy, contribution guide, keyless CI gates, and a domain-neutral two-tool device loop example.
- Framework gate: 76 Python tests and 52 Swift tests passed on 2026-08-08.

Task 21 also completed:

- Framework: 76 Python and 52 Swift tests passed.
- JianHao gateway + PoC: 815 tests passed after aligning six stale source assertions with the current adaptive-theme implementation.
- iPhone 17 / iOS 26.5 Simulator: 1,693 tests passed with no failure or skip; the streamed tomorrow-training card was captured in light and dark themes.
- Before the user limited subsequent deployment to Simulator only, an iPhone 17 Pro Max / iOS 26.5.2 ran 33 focused training-Agent, device-tool, confirmation, idempotency, protocol, and resume tests with no failure. No later physical-device command is authorized.
- Evidence report: `docs/product_goal_beacon_agent_v0_2_report.md` in the JianHao integration branch.

Task 22 completed:

- Independent review found no P0/P1 defect. Final hardening removed silent date fallback, made reusable action-group persistence visible in the confirmation copy, added latest-UI adapter compatibility evidence, enforced fail-closed knowledge review expiry/status checks, and expanded high-risk symptom refusal tests.
- Latest JianHao UI baseline `02679cc0` was preserved and the Agent commits were replayed onto `codex/beacon-agent-v0-2-merged`; original untracked design assets were excluded.
- Final JianHao gate: 819 Gateway + PoC tests passed; iPhone 17 / iOS 26.5 Simulator completed 1,714 tests with no failure or skip; the merged app launched on that Simulator.
- Framework gate remained 76 Python and 52 Swift tests passing.
- No push, tag, package publication, service deployment, or Release was performed.

Current state: BeaconAgentKit v0.2 implementation plan complete; awaiting explicit approval for any external publication.
