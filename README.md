# BeaconAgentKit

BeaconAgentKit is a protocol-first Agent platform and Swift-native interaction framework for Apple platforms. It connects capability discovery, staged routing, bounded model/tool loops, device-local execution, AG-UI streaming, A2UI surfaces, MCP Apps adapters, policy, and native SwiftUI rendering without forcing an app into a WebView chat UI.

BeaconAgentKit is not a model-provider SDK and not a domain app template. Its Python reference runtime and Swift packages are replaceable layers joined by versioned protocols:

```text
effective registry -> route -> model/tool/observation loop -> AG-UI/A2UI events
                  -> trusted device bridge -> native surface -> user decision
```

## Modules

- `BeaconAgentCore`: Foundation-only event, card, tool run, timeline, policy, and redaction primitives.
- `BeaconAgentSwiftUI`: Generic SwiftUI views for timelines, cards, and tool runs.
- `BeaconAgentAGUI`: Ordered AG-UI event decoding, streaming, reconnect, and resume cursors.
- `BeaconAgentA2UI`: Validated incremental surface state and actions.
- `BeaconAgentDevice`: Trusted host authorization, local tool execution, confirmation, and idempotency.
- `BeaconAgentMCP`: MCP tool and MCP Apps translation into the same capability and surface contracts.
- `BeaconAgentAppleEvents`: Pure model definitions for Apple app, notification, location, and motion events. It does not ship concrete HealthKit, ActivityKit, Watch, or notification adapters yet.
- `python/beacon_agent_runtime`: Signed registry snapshots, staged routing, bounded resumable runtime, policy, observability, knowledge, and evaluation reference implementations.

## Quick Start

```swift
import BeaconAgentCore
import BeaconAgentSwiftUI

var state = BeaconTimelineState()

state = BeaconTimelineReducer.reduce(
    state: state,
    event: .toolStarted(
        BeaconToolStartedEvent(
            toolRunId: "tool-1",
            toolName: "lookup",
            title: "Looking up reference data",
            inputSummary: "Searching local cache"
        )
    )
)

state = BeaconTimelineReducer.reduce(
    state: state,
    event: .toolFinished(
        BeaconToolFinishedEvent(
            toolRunId: "tool-1",
            outputSummary: "Found one matching record"
        )
    )
)

let card = BeaconCardEnvelope(
    id: "review-1",
    kind: "generic.review",
    title: "Review suggested update",
    subtitle: "Created by local reference lookup",
    status: .needsReview,
    source: BeaconCardSource(type: .tool, provider: "local-cache", description: "Reference lookup"),
    privacy: .localOnlyReview,
    accent: .system,
    payload: .json(
        type: "example.review",
        value: .object(["summary": .string("Found one matching record")])
    )
)

state = BeaconTimelineReducer.reduce(
    state: state,
    event: .cardCreated(BeaconCardCreatedEvent(card: card))
)

// Render with SwiftUI when the app wants a generic surface:
let view = BeaconTimelineView(state: state)
```

## Design Principles

- Swift-native first.
- Transport-agnostic.
- Privacy and redaction are core primitives.
- Domain-specific cards stay in the app.
- Generic card envelopes can carry typed JSON payloads.
- Unknown events are preserved as custom events.
- `BeaconAgentCore` remains Foundation-only.
- The effective registry is the strict intersection of server state, host support, schema compatibility, user authorization, and policy.
- The server may disable a capability but cannot grant device permission.
- Model output, MCP metadata, retrieved content, and remote manifests are untrusted.
- Consequential device writes require trusted identity, scope, confirmation, schema validation, and idempotency.
- Host apps own domain data, mutations, prompts, and product-specific renderers.

## Runtime and conformance tests

```bash
python3 -m venv .venv
.venv/bin/pip install -e './python[test]'
.venv/bin/python -m pytest python/tests -q
swift test
```

See the [device tool loop example](Examples/DeviceToolLoop/README.md), [architecture](docs/architecture.md), and [threat model](docs/threat-model.md).

## Non-Goals

- Bundled model-provider SDKs or vendor lock-in.
- A WebView chat shell.
- App-specific nutrition, training, supplement, posture, or medical models.
- Concrete HealthKit, ActivityKit, WatchConnectivity, CoreLocation, notification, or App Intents adapters.

## Status

BeaconAgentKit v0.2 is under review as an alpha platform contract. It is independently buildable and intentionally keeps product capability packs and user data outside this repository.

## License

Apache-2.0.
