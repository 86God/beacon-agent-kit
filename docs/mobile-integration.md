# BeaconAgentKit mobile integration boundary

## Supported baseline

BeaconAgentKit currently declares iOS 17, macOS 14, watchOS 10, tvOS 17, and
visionOS 1. A host should depend only on the products it uses. A device-first
assistant normally starts with:

- `BeaconAgentCore` for the v2 event envelope, deterministic projection, policy,
  capability manifests, protocol negotiation, and redaction.
- `BeaconAgentPersistence` for the ordered run journal and identifier-only
  durable outbox.
- `BeaconAgentDevice` for trusted account/scope/schema/expiry/confirmation checks
  before a local handler runs.
- `BeaconAgentMemory` only when the product has an explicit memory consent,
  review, expiry, profile-isolation, and deletion UX.
- `BeaconAgentAGUI`, `BeaconAgentA2UI`, and `BeaconAgentSwiftUI` only when the host
  needs their transport or rendering layers.

The host remains responsible for app identity, product permissions, domain
records, domain validation, model-provider credentials, and user-facing copy.

## Version and capability negotiation

1. Offer the versions actually implemented by both peers to
   `BeaconAgentProtocolNegotiator`; use only its highest common version.
2. Treat `upgrade_required` and `incompatible` as terminal for that request.
   Do not guess a schema or reinterpret an unknown critical event.
3. Intersect a server capability manifest with a device advertisement, supported
   schema version, enabled state, trusted scopes, and local policy. An advertised
   capability never grants permission by itself.
4. Keep `runId`, `turnId`, `toolCallId`, `approvalId`, and idempotency keys stable
   across reconnects. A new attempt may change `attemptId`; it must not change
   the logical run identity.

The current reusable event contract is schema version 2. Capability versions are
independent semantic versions and must be checked against each handler's declared
schema set.

## Registering a device tool

For every capability, register the same identifier in:

1. `BeaconDeviceCapabilityAdvertisement` — installed version, supported schema,
   enabled state.
2. `BeaconDevicePolicy` — exact required scopes, confirmation rule, closed input
   schema, and closed output schema.
3. A `BeaconDeviceToolHandler` — domain-owned implementation returning a
   `BeaconToolObservation`.

Construct `BeaconTrustedHostContext` from authenticated local state. Never accept
account, device, scope, or confirmation authority from model-generated arguments.
Consequential writes should require `beforeCommit` or `always`, carry an
idempotency key, persist a local receipt in the same mutation boundary, and emit
`receipt.committed` only after local read-back succeeds.

## Persistence adapters and restoration

Use `BeaconFilePersistenceStorage` for a single-process Apple host, or implement
`BeaconAgentPersistenceStorage` with compare-and-save semantics. The adapter must
provide atomic writes and fail on a stale expected value; silently overwriting a
newer journal can resurrect commands or lose events.

On launch or foreground activation:

1. Reopen `BeaconRunJournal`.
2. Inspect non-terminal runs and pending identifier-only outbox commands.
3. Reconnect from the durable cursor, or resolve a locally pending approval/tool
   using journaled data.
4. Reconcile a write through its local idempotency receipt before retrying.
5. Append exactly one terminal event or expose a retryable failure with a
   diagnostic identifier.

Do not store prompts, draft bodies, media, tool observations, credentials, or
health records in `BeaconOutboxCommand`. The event journal may contain local
display payloads, so place it in an app-protected directory and include it in
retention/deletion policy deliberately.

`BeaconMemoryFileRepository` is profile-scoped and revision checked. Only records
with authorization and evidence references can become active. Hosts must keep
`needsReview`, paused, expired, and deleted records out of recall and propagate
tombstones through their own backup/sync layer.

## Background behavior

The SDK does not claim unlimited background execution. When iOS suspends a host,
persist the last accepted event and any identifier-only resume command, cancel or
close network work cleanly, and resume from the cursor on the next allowed
foreground/background opportunity. Do not show a spinner as evidence that work
is still progressing. UI waiting state should be driven by meaningful events and
a host watchdog, and must end in success, explicit interruption, or error.

## Error recovery

- Duplicate event with identical identity and payload: safe replay.
- Same identity with different payload, mixed run/turn, gap, or late event after
  terminal: fail closed and recover from a snapshot or cursor query.
- Permission, account, scope, schema, expiry, or confirmation failure: do not call
  the handler and do not retry as a generic model request.
- Commit acknowledgement loss: query the local receipt and return the original
  result; never perform the mutation twice.
- Corrupt memory or persistence file: quarantine/preserve evidence and ask for a
  controlled recovery; never replace it with an empty store silently.

## Privacy responsibility

BeaconAgentKit provides boundaries, not legal consent. The integrating app must
define why each datum is needed, whether it leaves the device, how long it is
retained, how it is deleted/exported, and which profile owns it. Redact logs and
diagnostics; never log credentials, original photos, or health/note body text by
default. Remote model adapters must minimize note or health content and obtain
the required user authorization before upload.

## Independent consumption proof

`Examples/LocalNotesAssistant` is its own Swift package with a path dependency on
BeaconAgentKit. It exercises question -> read -> draft -> confirmation -> commit
-> restart -> restore using the SDK's device, event, persistence, outbox, receipt,
and memory boundaries. Run:

```bash
cd Examples/LocalNotesAssistant
swift test
```

The example contains no JianHao, HealthKit, nutrition, training, or product-view
dependency.

## Source of truth and release policy

The canonical repository is `https://github.com/86God/beacon-agent-kit.git`.
JianHao consumes it as a Git submodule at
`services/ai-gateway/vendor/beacon-agent-kit`; that path is a pinned checkout,
not a second authoritative copy.

Changes are committed and reviewed in the canonical repository first. After its
Swift and Python gates pass, merge to the canonical default branch and create a
SemVer tag. Consumer repositories then update only their pinned commit/tag and
run their integration tests. An untagged feature-branch SHA may be used for an
explicit integration trial, but it must not be described as a published SDK
release. Do not maintain divergent fixes independently in both repositories.
