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

## Current

- Task 4: Capability manifests and effective registry.
