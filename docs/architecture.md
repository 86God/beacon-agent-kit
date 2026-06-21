# BeaconAgentKit Architecture

BeaconAgentKit separates generic agent interaction mechanics from app-specific domain logic.

## Targets

- `BeaconAgentCore`: Foundation-only event, run, thread, tool run, card envelope, timeline reducer, policy, JSON payload, and redaction primitives.
- `BeaconAgentSwiftUI`: generic SwiftUI timeline, card stack, and tool run views.
- `BeaconAgentAGUI`: AG-UI-inspired event decoding and adapter entry points.
- `BeaconAgentAppleEvents`: Codable Apple-platform event model families without concrete framework adapters.

## Boundary

BeaconAgentKit owns generic agent runtime state:

```text
event -> redaction/policy primitives -> timeline reducer -> generic timeline state
```

Apps own domain payloads, network transports, prompts, persistence, and record mutation.
For example, a fitness app can wrap `food.review` as a generic `BeaconCardEnvelope`, but the actual food model stays in that app.

## Initial Non-Goals

- No backend streaming client.
- No LangGraph or model-provider SDK.
- No HealthKit, ActivityKit, WatchConnectivity, or App Intents adapters.
- No app-specific nutrition, supplement, training, or posture models.
