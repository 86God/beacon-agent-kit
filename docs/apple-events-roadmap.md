# Apple Events Roadmap

Milestone 0 includes pure Codable event models only. Concrete adapters come later.

## Current Models

- App lifecycle: launched, entered foreground, entered background.
- Notification: received, action tapped, dismissed.
- Location: entered region, exited region, significant change, visit detected.
- Motion: activity changed, stationary, walking, running, cycling.

## Later Adapters

- `v0.2`: app lifecycle and notification adapters.
- `v0.3`: location adapter with policy redaction.
- `v0.4`: ActivityKit and Live Activity surface routing.
- `v0.5`: HealthKit summary events.
- `v0.6`: WatchConnectivity bridge.

## Rule

Apple framework adapters must remain optional. Apps should be able to use `BeaconAgentCore` on its own without linking HealthKit, ActivityKit, CoreLocation, or WatchConnectivity.
