# AG-UI Compatibility

BeaconAgentKit is AG-UI-inspired and adapter-based in v0.1. The core event names intentionally mirror common run, message, tool, and card lifecycles while keeping Swift models independent from any single backend implementation.

## Supported Event Families

- `run.started`
- `run.finished`
- `run.error`
- `message.started`
- `message.delta`
- `message.finished`
- `tool.started`
- `tool.args.delta`
- `tool.finished`
- `tool.failed`
- `card.created`
- `card.updated`
- `custom`

Unknown event names decode to `BeaconAgentEvent.custom` so vendor extensions are preserved instead of dropped.

## Transport

v0.1 intentionally does not ship a streaming transport. Apps can decode newline-delimited JSON with `BeaconAGUIEventDecoder.decodeLines(_:)`, then feed events to `BeaconTimelineReducer`.

## Compatibility Strategy

BeaconAgentKit keeps wire compatibility concerns in `BeaconAgentAGUI` and native state concerns in `BeaconAgentCore`. If the public AG-UI protocol evolves, adapters can change without forcing SwiftUI views or app reducers to know about backend details.

## Event Safety

Event fields that are intended for display should already be summaries. BeaconAgentKit redacts summaries defensively, but raw images, base64 payloads, API keys, phone numbers, and provider-specific secrets should not be placed into event summaries in the first place.

## Timeline Semantics

The reducer treats `tool.started`, `tool.finished`, and `tool.failed` as updates to the same tool run when they share a `toolRunId`. Card events use the card `id` the same way: `card.updated` replaces the previous envelope instead of appending duplicate review cards.
