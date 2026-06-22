# BeaconAgentKit Status

## 2026-06-22 Phase 1

BeaconAgentKit v0.1 stabilization is focused on framework positioning, public API documentation, privacy-aware tests, and architecture docs.

Completed in this phase:

- Upgraded README positioning for a Swift-native AI interaction framework on Apple platforms.
- Added public API doc comments across core events, runs, threads, tool runs, cards, policy, redaction, AG-UI decoding, Apple event models, and generic SwiftUI views.
- Hardened tests for reducer tool failure upserts, nested JSON card payloads, image/base64 redaction, Apple motion events, and `BeaconAgentCore` import boundaries.
- Documented architecture, privacy policy model, AG-UI compatibility, Apple events roadmap, and demo app expectations.

Guardrails:

- `BeaconAgentCore` remains Foundation-only.
- BeaconAgentKit contains no app-specific food, supplement, workout, posture, prompt, or backend client models.
- Apple event support is model-only; no HealthKit, ActivityKit, Watch, notification, location, or App Intents adapters are implemented in v0.1.
