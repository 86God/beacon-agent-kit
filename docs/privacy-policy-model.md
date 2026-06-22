# Privacy Policy Model

BeaconAgentKit treats privacy as a core runtime primitive instead of a UI afterthought.

## v0.1 Defaults

- Raw media is local-only unless the host app requests explicit user consent.
- Health-like data should be summarized before it is sent to a cloud agent.
- Secrets, API-key-like tokens, phone numbers, and raw/base64 image payloads are redacted from display summaries.
- Record mutations should be represented as cards or actions that the host app can require the user to review.
- Card payloads should carry stable JSON summaries, not raw images, full OCR text dumps, or credentials.

## Current API

- `BeaconPrivacyLevel` classifies event/card sensitivity.
- `BeaconPolicy` describes what a host app allows for a target surface.
- `BeaconCardPrivacy` declares whether a card needs review, contains raw media, contains health data, or must stay local.
- `BeaconRedactor` sanitizes user-visible summaries and decoded event text.

## Redaction Scope

`BeaconRedactor` is intentionally small and deterministic. It protects display summaries from common accidental leaks:

- Raw `data:image/...;base64,...` values.
- `base64,...` image-like summaries.
- `imageDataBase64=...` debug summaries.
- API-key-like tokens.
- Mainland China mobile phone numbers.

It is not a compliance engine. Host apps should still enforce upload consent, retention policy, domain-specific validation, and review gates.

## Host App Responsibility

BeaconAgentKit does not decide whether a specific app may upload a photo, read a health sample, or schedule a notification. The host app evaluates policy using its own consent, entitlements, and product rules.

The package exposes primitives that make these decisions explicit, but the final decision belongs to the app.
