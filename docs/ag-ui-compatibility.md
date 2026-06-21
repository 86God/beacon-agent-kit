# AG-UI Compatibility

BeaconAgentKit is AG-UI-inspired and adapter-based in Milestone 0.

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

Milestone 0 intentionally does not ship a streaming transport. Apps can decode newline-delimited JSON with `BeaconAGUIEventDecoder.decodeLines(_:)`, then feed events to `BeaconTimelineReducer`.

## Compatibility Strategy

BeaconAgentKit keeps wire compatibility concerns in `BeaconAgentAGUI` and native state concerns in `BeaconAgentCore`. If the public AG-UI protocol evolves, adapters can change without forcing SwiftUI views or app reducers to know about backend details.
