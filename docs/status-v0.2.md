# BeaconAgentKit v0.2 Execution Status

Updated: 2026-08-08

## Starting state

- BeaconAgentKit start: `7baf68a` on `main`; implementation branch `codex/beacon-agent-v0-2`.
- JianHao start: `154d7b07` from `codex/open-agent-ui-stack`; isolated worktree branch `codex/beacon-agent-v0-2-integration`.
- The primary JianHao checkout had pre-existing nutrition/UI changes and reference assets. They remain untouched.

## Baseline evidence

- BeaconAgentKit Swift package: 18 tests passed.
- JianHao focused Agent/Assistant iOS Simulator test command exited successfully on iPhone 17, iOS 26.5.
- JianHao gateway initially failed collection because the isolated environment lacked `ag-ui-protocol` and `a2ui-agent-sdk`; this is an environment baseline issue, not an application assertion failure.
- The machine system Python is 3.11.1. A repository-local editable environment now runs Python 3.14.3, satisfying the package's Python >=3.12 requirement; its complete Python suite passes 29 tests.

## Completed

- Task 1 implementation: Python reference package scaffold and versioned event envelope; source tests pass under Python 3.11.
- Task 2 implementation: six closed JSON Schema 2020-12 wire contracts; 18 schema tests pass under Python 3.11.
- Task 3 implementation: shared JSONL fixtures plus deterministic Python and Swift reducers. Python suite passes 29 tests; Swift suite passes 18 XCTest tests plus 4 Swift Testing conformance tests.
- Task 4 implementation: immutable manifests, canonical hashes, effective-registry intersection, expiry/duplicate/cycle rejection, and Swift fixture decoding. Python suite passes 39 tests; Swift suite passes 18 XCTest tests plus 6 Swift Testing tests.
- Task 5 implementation: Ed25519 snapshot signing, tamper rejection, injected reference control plane, strict state endpoint, and OpenAPI documentation. Python suite passes 42 tests.
- Task 6 implementation: staged routing with host-resolved dates, workflow/approval continuation, effective-registry constraints, consequential clarification, and manifest-only offline fallback. Python suite passes 48 tests.
- Task 7 implementation: bounded model-tool loop, ordered events, safe retries, schema/policy enforcement, checkpoint resume, approval interrupt, and idempotent write replay. Python suite passes 55 tests; Swift suite remains green.
- Task 8 implementation: Foundation-only device bridge with trusted host context, account/scope/confirmation checks, request and result validation, in-flight exclusion, and completed idempotency replay. Full Swift suite passes 18 XCTest tests plus 10 Swift Testing tests.
- Task 9 implementation: byte-safe SSE parsing, CRLF/LF and multiline support, V2 decoding, resume headers, duplicate/gap handling, typed URLSession streaming, and exact Markdown whitespace preservation. Full Swift suite passes 18 XCTest tests plus 13 Swift Testing tests.
- Task 10 implementation: Foundation A2UI models/validator/store, atomic revisions and snapshot recovery, trusted-identity rejection, safe action catalog, and generic SwiftUI renderers with disabled unknown fallback. Full Swift suite passes 18 XCTest tests plus 17 Swift Testing tests.
- Task 11 implementation: progressive Markdown commits stable blocks during streaming, keeps only an incomplete tail provisional, renders code/tables/dividers, and shows redacted in-place activity rows. Full Swift suite passes 18 XCTest tests plus 23 Swift Testing tests; the package builds for iPhone 17 on iOS Simulator 26.5.
- Task 12 implementation: MCP tools map through host-owned policy profiles into capability manifests; structured results are schema-checked and redacted; embedded A2UI is catalog-validated; MCP Apps metadata requires negotiation; invalid/oversized resources and generic shell, SQL, or filesystem primitives fail closed. Python suite passes 61 tests and Swift passes 18 XCTest tests plus 28 Swift Testing tests; the iOS Simulator package build passes.
- Task 13 JianHao integration: four local-first training capability manifests declare strict schemas, dependencies, device execution, draft/write risks, confirmation, idempotency, and the versioned training draft surface. Three focused iOS Simulator tests pass; legacy ToolContract loading remains available for parity.
- Task 14 JianHao integration: all BeaconAgentKit products are linked; Markdown and both legacy SSE paths now use shared framework parsing through compatibility adapters; framework manifests and non-interactive A2UI are bridged into the host; domain cards, persistence, interactive renderers, handlers, and CapabilityKernel authorization remain product-owned. The focused AgentRuntime/AG-UI/A2UI/Markdown/ToolContract/CapabilityKernel simulator suite passes.
- Task 15 framework prerequisite: device-bound tool calls can now pause without server execution and resume only with a schema-valid host observation; invalid or mismatched observations leave the checkpoint pending. The Beacon Python suite passes 63 tests.
- Task 15 JianHao integration: the gateway consumes the sibling package as an editable dependency, resolves the strict server/host/compatibility/scope/policy capability intersection, streams stable v2 events before model completion, isolates runs by authenticated installation, and resumes device tools without synthesizing server health records. Existing v1 routes remain unchanged; the complete gateway suite passes 282 tests on Python 3.14.

## Current

- Task 16: Execute the training workflow through device-local tools.
