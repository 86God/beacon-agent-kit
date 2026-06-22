# BeaconAgentKit Architecture

BeaconAgentKit separates generic AI interaction mechanics from app-specific domain logic. The package is designed for Apple-platform apps that want native timelines, tool runs, review cards, and policy-aware event handling without moving product-specific models into a shared framework.

## Targets

- `BeaconAgentCore`: Foundation-only event, run, thread, tool run, card envelope, timeline reducer, policy, JSON payload, and redaction primitives.
- `BeaconAgentSwiftUI`: generic SwiftUI timeline, card stack, and tool run views.
- `BeaconAgentAGUI`: AG-UI-inspired event decoding and adapter entry points.
- `BeaconAgentAppleEvents`: Codable Apple-platform event model families without concrete framework adapters.

## Module Boundary

BeaconAgentKit owns generic agent runtime state:

```text
event -> redaction/policy primitives -> timeline reducer -> generic timeline state
```

Apps own domain payloads, network transports, prompts, persistence, and record mutation.

For example, a food, finance, learning, or productivity app can wrap a pending review result as a generic `BeaconCardEnvelope`, but the actual app record model, validation rules, and mutation side effects stay in that app.

## Data Flow

1. A host app receives or creates a `BeaconAgentEvent`.
2. Event summaries and card fields are redacted before display.
3. `BeaconTimelineReducer` projects messages, tool runs, and cards into `BeaconTimelineState`.
4. SwiftUI or app-specific views render that state.
5. The host app decides whether a card action mutates local records, calls a backend, or asks for more user review.

## Foundation-Only Core

`BeaconAgentCore` must remain usable without linking SwiftUI, UIKit, HealthKit, ActivityKit, CoreLocation, UserNotifications, or WatchConnectivity. Apple and SwiftUI integrations live in separate targets so server-side tests, command-line tools, and privacy-sensitive apps can adopt the core safely.

## v0.1 Non-Goals

- No backend streaming client.
- No LangGraph or model-provider SDK.
- No HealthKit, ActivityKit, WatchConnectivity, or App Intents adapters.
- No app-specific nutrition, supplement, training, or posture models.
- No WebView chat UI.
