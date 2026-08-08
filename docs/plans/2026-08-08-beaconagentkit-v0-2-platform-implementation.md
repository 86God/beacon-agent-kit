# BeaconAgentKit v0.2 Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Deliver a reusable, open-source BeaconAgentKit v0.2 Agent platform and prove it through JianHao's device-local “arrange shoulder training tomorrow” workflow.

**Architecture:** BeaconAgentKit owns protocol schemas, capability discovery, routing ports, the bounded Agent loop, policy primitives, AG-UI/A2UI/MCP adaptation, Swift client state, and generic native UI. JianHao consumes framework APIs through one adapter boundary and owns health data, local tools, training workflows, knowledge content, branded cards, and final writes.

**Tech Stack:** Swift 6, Swift Package Manager, SwiftUI, Python 3.12, Pydantic 2, FastAPI, JSON Schema 2020-12, Ed25519, AG-UI, A2UI v0.9, MCP, XCTest, pytest.

---

## 0. Repositories and safety boundaries

Framework repository:

~~~text
/Users/zhanggengying/Documents/beacon-agent-kit
implementation branch: codex/beacon-agent-v0-2
~~~

Product repository:

~~~text
/Users/zhanggengying/Documents/健身助手
integration branch: codex/beacon-agent-v0-2-integration
~~~

- [x] Run rtk git status --short --branch and rtk git log -5 --oneline --decorate in both repositories.
- [x] Preserve every pre-existing JianHao change. Do not stash, reset, clean, or commit unrelated UI assets and nutrition edits.
- [x] Create codex/beacon-agent-v0-2 from the current BeaconAgentKit main.
- [x] If JianHao is dirty, create an isolated integration worktree from the current committed codex/open-agent-ui-stack HEAD.
- [x] Record starting commits in docs/status-v0.2.md.
- [ ] Establish baselines with rtk swift test --package-path /Users/zhanggengying/Documents/beacon-agent-kit, rtk python3 -m pytest services/ai-gateway/tests -q, and the focused JianHao Agent/Assistant XCTest suite.
- [ ] Do not push, tag, publish, deploy, or merge into a dirty checkout until all gates pass and the user approves the external action.

Permanent rules:

~~~text
BeaconAgentKit runtime/library source never imports JianHao.
JianHao data reads and writes stay on the device.
The model cannot supply trusted identity, ownership, or permission fields.
Consequential writes require host authorization, confirmation, idempotency, and a receipt.
Capability manifests are declarations and never downloaded executable code.
~~~

## Milestone 1: Protocol foundation

### Task 1: Scaffold the Python reference package

**Files:**
- Create: python/pyproject.toml
- Create: python/beacon_agent_runtime/__init__.py
- Create: python/beacon_agent_runtime/protocol.py
- Create: python/tests/test_protocol.py

- [x] **Step 1: Write the failing round-trip test**

~~~python
from beacon_agent_runtime.protocol import AgentEvent, AgentEventType

def test_agent_event_round_trips() -> None:
    event = AgentEvent(
        schemaVersion=2,
        eventId="event-1",
        runId="run-1",
        sequence=1,
        type=AgentEventType.RUN_STARTED,
        payload={"threadId": "thread-1"},
    )
    assert AgentEvent.model_validate_json(event.model_dump_json()) == event
~~~

- [x] **Step 2: Run rtk python3 -m pytest python/tests/test_protocol.py -q and verify collection fails because the module is missing.**
- [x] **Step 3: Add Python >=3.12 metadata and Pydantic models.** Declare Pydantic, jsonschema, cryptography, FastAPI, httpx, and pytest with bounded major versions. AgentEvent is frozen, validates positive schemaVersion, non-empty IDs, and non-negative sequence. Install the editable test environment with rtk python3 -m pip install -e 'python[test]'. (Verified in an editable Python 3.14 environment, satisfying the Python >=3.12 gate.)
- [x] **Step 4: Rerun the test and expect 1 passed.**
- [x] **Step 5: Commit with feat(runtime): scaffold Python protocol package.**

### Task 2: Define language-neutral schemas

**Files:**
- Create: specs/agent-event.schema.json
- Create: specs/capability-manifest.schema.json
- Create: specs/run-input.schema.json
- Create: specs/route-decision.schema.json
- Create: specs/approval-request.schema.json
- Create: specs/execution-receipt.schema.json
- Create: python/tests/test_schemas.py

- [x] **Step 1: Test every schema with Draft202012Validator.check_schema.** Add valid fixtures and reject invalid capability versions, empty scopes, unsupported execution locations, unknown required fields, and model-supplied trusted identity fields.
- [x] **Step 2: Run the tests and verify missing-schema failures.**
- [x] **Step 3: Implement closed JSON Schema 2020-12 contracts.** Encode these stable enums:

~~~text
CapabilityKind: tool | skill | workflow | knowledge | surface
ExecutionLocation: server | device | either
Risk: read_only | reversible_draft | consequential_write | destructive
Confirmation: never | before_commit | always
Idempotency: none | optional | required
~~~

Agent events cover run, step, activity, text, tool, state, surface, approval, receipt, and error families. Namespaced custom events retain their payload.

- [x] **Step 4: Run pytest, python3 -m json.tool on every schema, and rtk git diff --check.**
- [x] **Step 5: Commit with feat(protocol): define v0.2 wire schemas.**

### Task 3: Add cross-language conformance

**Files:**
- Create: conformance/fixtures/tomorrow-training-run.jsonl
- Create: conformance/fixtures/tool-interrupt-resume.jsonl
- Create: conformance/fixtures/surface-stream.jsonl
- Create: python/beacon_agent_runtime/reducer.py
- Create: python/tests/test_conformance_replay.py
- Create: Sources/BeaconAgentCore/BeaconAgentEventV2.swift
- Create: Sources/BeaconAgentCore/BeaconAgentStateV2.swift
- Create: Tests/BeaconAgentCoreTests/BeaconAgentV2ConformanceTests.swift

- [x] **Step 1: Create an ordered run fixture with run.started, activity snapshot/delta, tool lifecycle, surface patches, approval interrupt, receipt, and run.finished.**
- [x] **Step 2: Write Python and Swift tests that produce the same normalized terminal JSON.** Replay duplicates and out-of-order events.
- [x] **Step 3: Implement minimal reducers.** Sequence gaps buffer; duplicate IDs with different payloads fail closed; unknown namespaced events are preserved.
- [x] **Step 4: Run:**

~~~bash
rtk python3 -m pytest python/tests/test_conformance_replay.py -q
rtk swift test --package-path /Users/zhanggengying/Documents/beacon-agent-kit
~~~

- [x] **Step 5: Commit with feat(protocol): add cross-language event conformance.**

## Milestone 2: Registry, routing, and Agent loop

### Task 4: Implement capability manifests and effective registry

**Files:**
- Create: python/beacon_agent_runtime/capabilities.py
- Create: python/beacon_agent_runtime/registry.py
- Create: python/tests/test_registry.py
- Create: Sources/BeaconAgentCore/BeaconCapabilityManifest.swift
- Create: Tests/BeaconAgentCoreTests/BeaconCapabilityManifestTests.swift

- [x] **Step 1: Write strict-intersection tests.**

~~~python
def test_effective_registry_is_strict_intersection() -> None:
    effective = registry.resolve(
        server_enabled={"training.plan.draft"},
        host_advertised={"training.plan.draft", "sleep.summary"},
        compatible={"training.plan.draft"},
        authorized_scopes={"training.read", "training.draft.write"},
        policy_allowed={"training.plan.draft"},
    )
    assert [item.id for item in effective.capabilities] == ["training.plan.draft"]
~~~

Also test disabled, absent, incompatible, unauthorized, expired, duplicate, and dependency-cycle manifests.

- [x] **Step 2: Implement immutable manifests and snapshots.** Snapshot fields are revision, environment, issuedAt, expiresAt, manifest hashes, and signature. Canonicalize JSON before hashing.
- [x] **Step 3: Add Swift decoding of Python fixtures and reject unsupported required schema versions.**
- [x] **Step 4: Run Python and Swift suites.**
- [x] **Step 5: Commit with feat(registry): resolve effective capabilities.**

### Task 5: Add signed snapshots and control-plane reference API

**Files:**
- Create: python/beacon_agent_runtime/signing.py
- Create: python/beacon_agent_runtime/control_plane.py
- Create: python/tests/test_control_plane.py
- Create: control-plane/openapi.yaml
- Create: control-plane/reference/README.md

- [x] **Step 1: Test Ed25519 signing and tamper rejection with ephemeral test keys.**
- [x] **Step 2: Test these endpoints:**

~~~text
GET /v1/capabilities
PUT /v1/capabilities/{capability_id}/state
GET /v1/registry/snapshot?environment=development
~~~

Unknown IDs return 404, invalid manifests return 422, state changes increment revision, and the API never grants user permission.

- [x] **Step 3: Implement FastAPI with an in-memory test store and a RegistryStore protocol.** Inject private keys; commit no keys.
- [x] **Step 4: Run rtk python3 -m pytest python/tests/test_control_plane.py -q.**
- [x] **Step 5: Commit with feat(control-plane): publish signed capability snapshots.**

### Task 6: Implement staged intent routing

**Files:**
- Create: python/beacon_agent_runtime/routing.py
- Create: python/beacon_agent_runtime/providers.py
- Create: python/tests/test_routing.py

- [x] **Step 1: Write cases proving explicit dates, active approvals, disabled capabilities, low-confidence consequential ambiguity, and read-only lookup behavior.**
- [x] **Step 2: Define CapabilityRetriever and CapabilityReranker protocols.** The reranker may choose only from the supplied candidate IDs.
- [x] **Step 3: Implement precedence: pending workflow, explicit structured context, host-resolved date, attachment class, manifest retrieval, constrained reranking.** Keyword routing is only an offline fallback driven by manifest tags.
- [x] **Step 4: Run rtk python3 -m pytest python/tests/test_routing.py -q.**
- [x] **Step 5: Commit with feat(router): add staged capability routing.**

### Task 7: Implement the bounded iterative runtime

**Files:**
- Create: python/beacon_agent_runtime/runtime.py
- Create: python/beacon_agent_runtime/checkpoints.py
- Create: python/beacon_agent_runtime/policy.py
- Create: python/beacon_agent_runtime/events.py
- Create: python/tests/test_agent_loop.py
- Create: python/tests/test_agent_recovery.py

- [x] **Step 1: Use a fake model to test this sequence:**

~~~text
request training.context.read
receive observation
request exercise.candidates.search
receive observation
request training.plan.draft
receive draft
request approval interrupt
~~~

Assert every tool follows the prior observation and events arrive before run completion.

- [x] **Step 2: Test step/tool/retry limits, observation size, invalid schemas, unknown tools, policy denial, checkpoint resume, and idempotent write retry.**
- [x] **Step 3: Implement the loop through ModelProvider, ToolDispatcher, CheckpointStore, PolicyEngine, EventSink, and RegistryProvider protocols.** Emit safe activity summaries, never raw chain-of-thought.
- [x] **Step 4: Run both runtime test files.**
- [x] **Step 5: Commit with feat(runtime): execute bounded resumable agent loops.**

## Milestone 3: Swift device bridge and streaming UI

### Task 8: Add device execution contracts

**Files:**
- Modify: Package.swift
- Create: Sources/BeaconAgentDevice/BeaconDeviceCapabilityAdvertisement.swift
- Create: Sources/BeaconAgentDevice/BeaconDeviceToolRequest.swift
- Create: Sources/BeaconAgentDevice/BeaconDeviceToolDispatcher.swift
- Create: Sources/BeaconAgentDevice/BeaconDevicePolicy.swift
- Create: Tests/BeaconAgentDeviceTests/BeaconDeviceToolDispatcherTests.swift

- [x] **Step 1: Test disabled, incompatible, missing-scope, wrong-account, unconfirmed, expired, duplicate-in-flight, invalid-schema, and completed-idempotency cases.**
- [x] **Step 2: Add a Foundation-only BeaconAgentDevice target.**
- [x] **Step 3: Implement the handler contract:**

~~~swift
public protocol BeaconDeviceToolHandler: Sendable {
    var capabilityID: String { get }
    func execute(_ request: BeaconAuthorizedToolRequest) async throws -> BeaconToolObservation
}
~~~

Trusted identity and scope come only from BeaconTrustedHostContext.

- [x] **Step 4: Run the full Swift package suite.**
- [x] **Step 5: Commit with feat(device): add local capability execution bridge.**

### Task 9: Upgrade AG-UI streaming and resume

**Files:**
- Modify: Sources/BeaconAgentAGUI/BeaconAGUIEventDecoder.swift
- Create: Sources/BeaconAgentAGUI/BeaconAGUISSEParser.swift
- Create: Sources/BeaconAgentAGUI/BeaconAGUIStreamClient.swift
- Create: Sources/BeaconAgentAGUI/BeaconAGUIResumeCursor.swift
- Create: Tests/BeaconAgentAGUITests/BeaconAGUIStreamingTests.swift

- [x] **Step 1: Port generic JianHao SSE tests for split chunks, CRLF/LF, multiline data, IDs, reconnect headers, duplicates, gaps, and Markdown whitespace.**
- [x] **Step 2: Implement URLSession AsyncSequence streaming and typed failures.** Never trim text deltas.
- [x] **Step 3: Assert concatenated deltas exactly equal finalText.**
- [x] **Step 4: Run focused and full Swift tests.**
- [x] **Step 5: Commit with feat(agui): stream and resume agent events.**

### Task 10: Add A2UI runtime and renderer catalogs

**Files:**
- Modify: Package.swift
- Create: Sources/BeaconAgentA2UI/BeaconA2UIModels.swift
- Create: Sources/BeaconAgentA2UI/BeaconA2UIValidator.swift
- Create: Sources/BeaconAgentA2UI/BeaconA2UIStore.swift
- Create: Sources/BeaconAgentA2UI/BeaconA2UIActionEnvelope.swift
- Create: Tests/BeaconAgentA2UITests/BeaconA2UIConformanceTests.swift
- Create: Sources/BeaconAgentSwiftUI/BeaconSurfaceRendererCatalog.swift
- Create: Sources/BeaconAgentSwiftUI/BeaconGenericSurfaceView.swift

- [x] **Step 1: Test create/update/snapshot/patch/complete plus unknown component, cycle, dangling reference, identity injection, oversized text, invalid action, and revision gap.**
- [x] **Step 2: Implement Foundation-only A2UI state with atomic patching and snapshot recovery.**
- [x] **Step 3: Add generic Text, Row, Column, Card, Button, Metric, List, Table, Notice, Error, Retry, Approval, and Receipt renderers.** Unknown surfaces use safe text fallback with actions disabled.
- [x] **Step 4: Run Swift tests.**
- [x] **Step 5: Commit with feat(a2ui): add validated streaming surface runtime.**

### Task 11: Extract progressive Markdown and activity UI

**Files:**
- Create: Sources/BeaconAgentSwiftUI/BeaconIncrementalMarkdown.swift
- Create: Sources/BeaconAgentSwiftUI/BeaconAgentActivityView.swift
- Create: Sources/BeaconAgentSwiftUI/BeaconAgentMessageView.swift
- Create: Tests/BeaconAgentSwiftUITests/BeaconIncrementalMarkdownTests.swift
- Modify: Package.swift

- [x] **Step 1: Port JianHao tests for headings, lists, code fences, tables, emphasis, links, Chinese punctuation, and incomplete trailing blocks.**
- [x] **Step 2: Render completed blocks immediately and only the incomplete tail provisionally.** Finalization must not restyle completed blocks.
- [x] **Step 3: Render activity/tool rows in place using redacted summaries.**
- [x] **Step 4: Run full Swift tests and an iOS Simulator package build.**
- [x] **Step 5: Commit with feat(ui): add progressive markdown and agent activity views.**

### Task 12: Add MCP and MCP Apps adapters

**Files:**
- Modify: Package.swift
- Create: Sources/BeaconAgentMCP/BeaconMCPModels.swift
- Create: Sources/BeaconAgentMCP/BeaconMCPToolAdapter.swift
- Create: Sources/BeaconAgentMCP/BeaconMCPResourceResolver.swift
- Create: Tests/BeaconAgentMCPTests/BeaconMCPAdapterTests.swift
- Create: python/beacon_agent_runtime/mcp.py
- Create: python/tests/test_mcp.py

- [x] **Step 1: Test tools, schemas, structured results, embedded A2UI, negotiated MCP Apps, invalid URIs, oversized resources, forbidden shell/SQL/filesystem tools, redaction, and confirmation-required results.**
- [x] **Step 2: Map MCP tools into CapabilityManifest and the same policy/receipt path.** MCP resources cannot bypass native catalogs or action validation.
- [x] **Step 3: Run Python and Swift suites.**
- [x] **Step 4: Commit with feat(mcp): adapt MCP tools and app resources.**

## Milestone 4: JianHao integration

### Task 13: Register the JianHao training capability pack

**Files:**
- Create: ios/JianHaoPoC/JianHaoPoC/Resources/AICapabilities/training.context.read.v1.json
- Create: ios/JianHaoPoC/JianHaoPoC/Resources/AICapabilities/exercise.candidates.search.v1.json
- Create: ios/JianHaoPoC/JianHaoPoC/Resources/AICapabilities/training.plan.draft.v1.json
- Create: ios/JianHaoPoC/JianHaoPoC/Resources/AICapabilities/training.plan.commit.v1.json
- Create: ios/JianHaoPoC/JianHaoPoCTests/JianHaoCapabilityManifestTests.swift
- Modify: ios/JianHaoPoC/JianHaoPoC.xcodeproj/project.pbxproj

- [x] **Step 1: Test unique IDs, dependencies, and these policies:**

~~~text
context/search: read_only, device
draft: reversible_draft, device
commit: consequential_write, before_commit, idempotency required, device
~~~

- [x] **Step 2: Add resources and keep the old ToolContract loader until parity tests pass.**
- [x] **Step 3: Run the focused manifest XCTest.**
- [x] **Step 4: Commit with feat(ai): register JianHao training capabilities.**

### Task 14: Replace duplicate generic Swift code with package adapters

**Files:**
- Modify: ios/JianHaoPoC/JianHaoPoC.xcodeproj/project.pbxproj
- Modify: ios/JianHaoPoC/JianHaoPoC/BeaconAgentKitAdapters.swift
- Modify: ios/JianHaoPoC/JianHaoPoC/AgentRuntimeAssistantCardAdapter.swift
- Modify: ios/JianHaoPoC/JianHaoPoC/JianHaoA2UICatalog.swift
- Modify: ios/JianHaoPoC/JianHaoPoC/AICapability/CapabilityKernel.swift
- Test: existing AgentRuntime, AGUI, A2UI, IncrementalMarkdown, CapabilityKernel, and ToolContract tests

- [x] **Step 1: Add local package products BeaconAgentCore, AGUI, A2UI, Device, MCP, and SwiftUI.**
- [x] **Step 2: Replace generic event, reducer, SSE, A2UI, Markdown, registry, and lifecycle ownership with imports or thin adapters.**
- [x] **Step 3: Keep FoodPhotoEstimate, ExerciseRecordEstimate, training workflow/persistence, domain cards, and local handlers in JianHao.**
- [x] **Step 4: Run focused tests before and after removing proven duplicates.**
- [x] **Step 5: Commit only intended package, adapter, removed-source, and test files with refactor(ai): consume BeaconAgentKit runtime and UI.**

### Task 15: Host the runtime in the JianHao gateway

**Files:**
- Modify: services/ai-gateway/pyproject.toml
- Modify: services/ai-gateway/jianhao_ai_gateway/app.py
- Create: services/ai-gateway/jianhao_ai_gateway/beacon_host.py
- Create: services/ai-gateway/jianhao_ai_gateway/jianhao_capability_pack.py
- Modify: services/ai-gateway/tests/test_agent_runtime_v1.py
- Create: services/ai-gateway/tests/test_beacon_host.py

- [x] **Step 1: Test effective registry, device-tool pause/resume, schema-valid observations, stable IDs, early events, and absence of server-synthesized health observations.**
- [x] **Step 2: Add the sibling Python package as a local editable dependency.** Copy no generic runtime module into JianHao.
- [x] **Step 3: Wire JianHao providers through beacon_host.py and keep old endpoints compatible through adapters.**
- [x] **Step 4: Run rtk python3 -m pytest services/ai-gateway/tests -q.** Verified with the gateway's editable Python 3.14 environment: 282 passed; the machine `python3` remains 3.11 and is below the declared >=3.12 runtime gate.
- [x] **Step 5: Commit with feat(gateway): host BeaconAgentKit runtime.**

### Task 16: Execute the training workflow through device-local tools

**Files:**
- Modify: ios/JianHaoPoC/JianHaoPoC/AICapability/TrainingCapabilityAdapter.swift
- Modify: ios/JianHaoPoC/JianHaoPoC/AICapability/CapabilityKernel.swift
- Modify: ios/JianHaoPoC/JianHaoPoC/AICapability/AITrainingPlanCoordinator.swift
- Modify: ios/JianHaoPoC/JianHaoPoC/AICapability/TrainingTodayCommitTransaction.swift
- Create: ios/JianHaoPoC/JianHaoPoC/AICapability/JianHaoDeviceToolBridge.swift
- Modify: ios/JianHaoPoC/JianHaoPoCTests/AITrainingPlanCoordinatorTests.swift
- Create: ios/JianHaoPoC/JianHaoPoCTests/JianHaoDeviceToolBridgeTests.swift

- [x] **Step 1: Fix Calendar to Asia/Shanghai and test “安排一下明天练肩”.** Require context, candidates, draft, tomorrow dayIdentifier, confirmation, tomorrow commit, unchanged today, and local read-back.
- [x] **Step 2: Test identity injection rejection, confirmation, idempotency, thread ownership, and rejection of server-origin health records.**
- [x] **Step 3: Register existing handlers through JianHaoDeviceToolBridge.** Keep CapabilityKernel as final authorization until parity is proved.
- [x] **Step 4: Run coordinator, bridge, and adapter XTests.**
- [x] **Step 5: Commit with feat(ai): execute training plans through local tools.**

### Task 17: Render the streaming Agent timeline and training card

**Files:**
- Modify: ios/JianHaoPoC/JianHaoPoC/AICapability/AITrainingPlanCards.swift
- Modify: ios/JianHaoPoC/JianHaoPoC/A2UIRenderer.swift
- Modify: ios/JianHaoPoC/JianHaoPoC/AINativeChatScreen.swift
- Modify: ios/JianHaoPoC/JianHaoPoC/AINativeChatSurface.swift
- Modify: ios/JianHaoPoC/JianHaoPoC/AssistantCardViews.swift
- Modify: ios/JianHaoPoC/JianHaoPoC/AssistantToolRunView.swift
- Modify: ios/JianHaoPoC/JianHaoPoCTests/A2UIRendererTests.swift
- Create: ios/JianHaoPoC/JianHaoPoCUITests/AITrainingAgentFlowUITests.swift

- [x] **Step 1: Test in-place activity transitions: querying training, equipment, candidates, and draft.**
- [x] **Step 2: Register training.plan.draft@1 as a JianHao renderer.** It appears at surface start, patches in place, supports edit/replace/reorder, preserves date, and disables commit while writing.
- [x] **Step 3: Use BeaconAgentMessageView and BeaconAgentActivityView for generic content.** Never fall back to a Markdown table when the catalog is present.
- [x] **Step 4: Run the complete iOS Simulator test suite and capture approved light/dark evidence.**
- [x] **Step 5: Commit with feat(ai-ui): stream agent activity and training surfaces.**

## Milestone 5: Knowledge, evaluation, and release readiness

### Task 18: Add knowledge-pack contracts

**Files:**
- Create: specs/knowledge-manifest.schema.json
- Create: python/beacon_agent_runtime/knowledge.py
- Create: python/tests/test_knowledge.py
- Create: Sources/BeaconAgentCore/BeaconKnowledgeManifest.swift
- Create: Tests/BeaconAgentCoreTests/BeaconKnowledgeManifestTests.swift

- [x] **Step 1: Reject missing source ID, URL, reuse status, locale, version, and citation policy.**
- [x] **Step 2: Require evidence-marked answers to cite a retrieved passage.**
- [x] **Step 3: Implement provider-neutral corpus, query, passage, citation, and retriever models.**
- [x] **Step 4: Run Python and Swift suites.**
- [x] **Step 5: Commit with feat(knowledge): define cited knowledge-pack contracts.**

### Task 19: Build JianHao private-coach knowledge pack v1

**Files:**
- Create: poc/data/knowledge/private_coach_v1/manifest.json
- Create: poc/data/knowledge/private_coach_v1/sources.json
- Create: poc/data/knowledge/private_coach_v1/principles.jsonl
- Create: poc/data/knowledge/private_coach_v1/evaluation.jsonl
- Create: poc/tools/validate_private_coach_knowledge.py
- Create: poc/tests/test_private_coach_knowledge.py
- Create: services/ai-gateway/jianhao_ai_gateway/private_coach_knowledge.py

- [x] **Step 1: Use authoritative sources and original JianHao summaries.** Seed the source registry with the WHO 2020 physical-activity guideline (https://www.who.int/publications/i/item/9789240014886), the current U.S. Physical Activity Guidelines page (https://odphp.health.gov/our-work/nutrition-physical-activity/physical-activity-guidelines/current-guidelines), and the current ACSM resistance-training position-stand page (https://acsm.org/resistance-training-guidelines-update-2026/). Treat source authority, commercial reuse, content review, and release approval as separate gates. Do not ingest ACSM copyrighted text; store original summaries and citations unless explicit reuse terms permit more.
- [x] **Step 2: Reject unsupported diagnosis/treatment, uncited numeric advice, expired review, and missing locale.**
- [x] **Step 3: Cover progressive overload, volume/intensity basics, recovery, warm-up, pain stop conditions, beginner adaptation, equipment constraints, and professional referral.**
- [x] **Step 4: Test citations, missing-evidence admission, and medical-boundary refusal.**
- [x] **Step 5: Run PoC report and gateway tests.**
- [x] **Step 6: Commit with feat(ai): add cited private-coach knowledge pack.**

### Task 20: Add evaluation, security docs, CI, and example

**Files:**
- Create: python/beacon_agent_runtime/evals.py
- Create: python/tests/test_evals.py
- Create: docs/threat-model.md
- Create: SECURITY.md
- Create: CONTRIBUTING.md
- Create: .github/workflows/ci.yml
- Create: Examples/DeviceToolLoop/README.md
- Modify: README.md
- Modify: docs/architecture.md
- Modify: docs/status.md

- [x] **Step 1: Measure route recall, capability precision, unnecessary tool calls, clarification correctness, policy violations, completion, surface fallback, and task success.**
- [x] **Step 2: Document prompt injection, malicious manifests, identity spoofing, schema smuggling, MCP injection, replay, duplicate writes, sensitive logs, registry-key compromise, and unsafe knowledge.**
- [x] **Step 3: Run Python, Swift, schema, boundary, and fixture tests in CI without production keys.**
- [x] **Step 4: Add a domain-neutral local-task example with two tools, approval, surface patching, and idempotent commit.**
- [x] **Step 5: Run the complete framework gate and commit with docs: prepare BeaconAgentKit v0.2 for review.**

## Milestone 6: Integrated verification

### Task 21: Run the complete regression matrix

**Files:**
- Create: docs/product_goal_beacon_agent_v0_2_report.md in JianHao

- [ ] **Step 1: Run framework gates:**

~~~bash
rtk python3 -m pytest python/tests -q
rtk swift test --package-path /Users/zhanggengying/Documents/beacon-agent-kit
~~~

- [ ] **Step 2: Run JianHao gateway and PoC gates:**

~~~bash
rtk python3 -m pytest services/ai-gateway/tests poc/tests -q
rtk python3 poc/tools/build_poc_report.py
rtk ./poc/ios-physical-readiness.sh
~~~

- [ ] **Step 3: Run the complete iOS Simulator suite:**

~~~bash
rtk xcodebuild -project ios/JianHaoPoC/JianHaoPoC.xcodeproj -scheme JianHaoPoC -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' test
~~~

- [ ] **Step 4: Verify on a physical device:** authenticated streaming, reconnect, local reads, edit/replace/reorder, confirmation, tomorrow persistence, idempotent retry, and local read-back. Report signing blockers separately.
- [ ] **Step 5: Record commits, commands, pass/fail counts, screenshots, privacy evidence, timings, blockers, and live-service usage in the report.**
- [ ] **Step 6: Commit the evidence report.**

### Task 22: Review and prepare merge

- [ ] **Step 1: Inspect branch logs and diff stats in both repositories.**
- [ ] **Step 2: Confirm JianHao diff excludes pre-existing user changes.**
- [ ] **Step 3: Review first for privacy boundaries, unauthorized writes, incompatibility, replay/idempotency, date loss, non-streaming UI, and missing device evidence.**
- [ ] **Step 4: Fix correctness findings and rerun affected gates.**
- [ ] **Step 5: Merge locally only when no user-owned change can be overwritten. Otherwise preserve verified branches and report the exact blocker.**
- [ ] **Step 6: Stop before push, tag, release, package publication, or deployment. Provide proposed external commands and verified commit IDs for user approval.**

## Final done criteria

~~~text
BeaconAgentKit is domain-neutral and independently buildable.
Admin enable/disable changes the effective registry.
Routing uses deterministic context, retrieval, and constrained reranking.
The runtime performs multiple model/tool/observation iterations.
Device tools enforce trusted identity, permission, confirmation, and idempotency.
AG-UI activities/tools/text and A2UI surfaces render during streaming.
JianHao shows the editable training draft card instead of Markdown fallback.
“安排一下明天练肩” commits to tomorrow and verifies through a local read.
Private-coach answers cite reviewed knowledge and admit missing evidence.
Framework, gateway, PoC, Simulator, and physical-device results are exact.
No unrelated user changes are overwritten or committed.
No external publication occurs without explicit user approval.
~~~
