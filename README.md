# BeaconAgentKit

BeaconAgentKit is a Swift-native AI interaction framework for Apple platforms.
It connects agent events, device-adjacent event models, privacy policy, timeline state, and native SwiftUI surfaces without forcing an app into a WebView chat UI.

BeaconAgentKit is not a model SDK, not a backend framework, and not a domain app template. It is the client-side event and surface layer that helps an Apple-platform app turn agent activity into native state:

```text
agent event -> policy/redaction -> timeline reducer -> native surface -> user decision
```

## Modules

- `BeaconAgentCore`: Foundation-only event, card, tool run, timeline, policy, and redaction primitives.
- `BeaconAgentSwiftUI`: Generic SwiftUI views for timelines, cards, and tool runs.
- `BeaconAgentAGUI`: AG-UI-inspired event decoding and mapping.
- `BeaconAgentAppleEvents`: Pure model definitions for Apple app, notification, location, and motion events. It does not ship concrete HealthKit, ActivityKit, Watch, or notification adapters yet.

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

## Non-Goals

BeaconAgentKit v0.1 intentionally does not include:

- Model-provider SDKs or prompt orchestration.
- Backend streaming transports.
- A WebView chat shell.
- App-specific nutrition, training, supplement, posture, or medical models.
- Concrete HealthKit, ActivityKit, WatchConnectivity, CoreLocation, notification, or App Intents adapters.

## Status

BeaconAgentKit is stabilizing for v0.1. The current package focuses on generic event contracts, redaction, reducers, model-only Apple event envelopes, and lightweight SwiftUI rendering.

## License

Apache-2.0.
