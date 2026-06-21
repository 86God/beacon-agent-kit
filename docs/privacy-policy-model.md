# Privacy Policy Model

BeaconAgentKit treats privacy as a core runtime primitive instead of a UI afterthought.

## Defaults

- Raw media is local-only unless the host app requests explicit user consent.
- Health-like data should be summarized before it is sent to a cloud agent.
- Secrets, API-key-like tokens, phone numbers, and raw/base64 image payloads are redacted from display summaries.
- Record mutations should be represented as cards or actions that the host app can require the user to review.

## Current API

- `BeaconPrivacyLevel` classifies event/card sensitivity.
- `BeaconPolicy` describes what a host app allows for a target surface.
- `BeaconCardPrivacy` declares whether a card needs review, contains raw media, contains health data, or must stay local.
- `BeaconRedactor` sanitizes user-visible summaries and decoded event text.

## Host App Responsibility

BeaconAgentKit does not decide whether a specific app may upload a photo, read a health sample, or schedule a notification. The host app evaluates policy using its own consent, entitlements, and product rules.
