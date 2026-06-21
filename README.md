# BeaconAgentKit

BeaconAgentKit is a Swift-native agent interaction framework for Apple platforms.
It connects agent events, privacy policy, timeline state, and native SwiftUI surfaces without forcing an app into a WebView chat UI.

BeaconAgentKit is not a model SDK and not a backend framework. It is the client-side event and surface layer that helps an Apple-platform app turn agent streams into native state:

```text
agent event -> policy/redaction -> timeline reducer -> native surface -> user decision
```

## Modules

- `BeaconAgentCore`: Foundation-only event, card, tool run, timeline, policy, and redaction primitives.
- `BeaconAgentSwiftUI`: Generic SwiftUI views for timelines, cards, and tool runs.
- `BeaconAgentAGUI`: AG-UI-inspired event decoding and mapping.
- `BeaconAgentAppleEvents`: Pure model definitions for Apple app, notification, location, and motion events.

## First Example

```swift
import BeaconAgentCore

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
```

## Design Principles

- Swift-native first.
- Transport-agnostic.
- Privacy and redaction are core primitives.
- Domain-specific cards stay in the app.
- Generic card envelopes can carry typed JSON payloads.
- Unknown events are preserved as custom events.

## Status

BeaconAgentKit is in extraction planning. The first milestone is a small Swift Package scaffold with tests for event decoding, redaction, and timeline reduction.

## License

Apache-2.0.
