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

## Current

- Task 8: Swift device execution contracts.
