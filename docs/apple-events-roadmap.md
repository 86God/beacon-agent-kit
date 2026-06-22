# Apple Events Roadmap

v0.1 includes pure Codable event models only. Concrete adapters come later and will remain optional.

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

## Policy Direction

Future adapters should emit model objects that can be evaluated by `BeaconPolicy` before data leaves the device or triggers a native surface. For example, approximate location and notification summaries can be modeled generically, while precise location, health samples, and raw notification content should require explicit host-app policy and consent checks.

## What v0.1 Does Not Do

The package does not request permissions, subscribe to system callbacks, schedule notifications, start Live Activities, write HealthKit samples, or communicate with a watch. It only defines the portable event shapes those adapters can use later.
