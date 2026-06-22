# BeaconAgentDemo

This folder is reserved for a small demo app after the package core stabilizes for v0.1.

The first demo should show:

1. A `tool.started` event.
2. A `tool.finished` event updating the same tool run.
3. A `card.created` event rendering a generic review card.
4. A user confirmation action owned by the demo app.

The demo must use generic reference data only. It should not import or recreate any host-app business models, prompts, food schemas, supplement schemas, workout records, or backend clients.

## Suggested Flow

1. Build a `BeaconTimelineState`.
2. Apply a local `BeaconToolStartedEvent`.
3. Apply a matching `BeaconToolFinishedEvent` with the same `toolRunId`.
4. Apply a `BeaconCardCreatedEvent` with a JSON payload such as `example.review`.
5. Render `BeaconTimelineView` and let the demo app handle any button tap.
