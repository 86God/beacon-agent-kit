# BeaconAgentKit v0.2 Threat Model

## Scope and trust boundaries

BeaconAgentKit coordinates a server-side control plane and Agent runtime with a host application that owns user identity, permissions, local data, UI, and final mutations. The model, retrieved content, MCP metadata, remote registry data, and transport payloads are untrusted inputs.

The framework protects these assets:

- user identity, local records, health-adjacent data, and account boundaries;
- capability availability, authorization scope, confirmation, and execution location;
- integrity of consequential writes and their idempotency receipts;
- confidentiality of prompts, observations, logs, and knowledge passages;
- integrity of signed registry snapshots, schemas, surfaces, and citations.

The server may enable or disable a capability, but it cannot grant device permission. The effective capability set is the strict intersection of server-enabled, host-advertised, schema-compatible, user-authorized, and policy-allowed capabilities. The device bridge must derive identity and scope from trusted host context, never from model arguments.

## Threats and required controls

### Prompt and retrieved-content injection

An attachment, tool observation, knowledge passage, or user record may contain instructions that attempt to override policy or invoke a tool.

Controls:

- treat retrieved and observed text as data, not control-plane instructions;
- select tools only from the effective registry and validate arguments against the registered schema;
- re-run policy and authorization checks at execution time;
- require explicit confirmation for consequential or destructive writes;
- bound steps, tool calls, retries, and observation size.

Residual risk: a model can still choose an irrelevant eligible tool. Offline evaluation and host-visible Agent activity are required to detect routing drift.

### Malicious or compromised capability manifests

A manifest may request excessive scopes, hide a write as a read, advertise an incompatible schema, create dependency cycles, or smuggle unknown fields.

Controls:

- closed JSON Schemas and immutable parsed manifests;
- signed, expiring, revisioned registry snapshots with canonical JSON hashing;
- strict-intersection resolution and dependency-cycle rejection;
- host-owned risk, execution-location, permission, and confirmation enforcement;
- unsupported required schema versions fail closed.

### Identity or authorization spoofing

Model-generated arguments or remote payloads may claim another user, account, tenant, permission, or approval.

Controls:

- trusted identity and granted scopes enter only through `BeaconTrustedHostContext`;
- device requests are rejected for the wrong account, missing scope, expired authorization, or mismatched registry revision;
- approval IDs are bound to the run, tool call, capability, scopes, and idempotency key;
- tools do not accept identity-bearing arguments when the host can supply identity out of band.

### Schema smuggling and oversized observations

Attackers may exploit permissive nested objects, nullable values, duplicate keys, unknown event fields, or very large tool results.

Controls:

- Draft 2020-12 validation for inputs and observations, including nested and nullable schemas;
- closed wire schemas where forward-compatible extension points are not explicitly defined;
- maximum observation bytes and bounded event payloads;
- unknown A2UI component types and unsafe actions render a fallback or are rejected, never executed.

### MCP tool and MCP Apps injection

Remote MCP descriptions, annotations, resources, or embedded UI metadata may misrepresent side effects or introduce unsafe actions.

Controls:

- translate MCP tools into ordinary capability manifests and distrust annotations;
- apply the same registry, policy, scope, confirmation, schema, and idempotency rules as native tools;
- allow only negotiated catalogs and resource origins;
- never let MCP content bypass the host renderer catalog or device dispatcher.

### Replay and duplicate writes

Network retries, reconnects, model repetition, or malicious replay may execute a write twice.

Controls:

- consequential writes require a stable idempotency key;
- in-flight duplicate tool calls are rejected;
- completed receipts are replayed without invoking the handler again;
- checkpoints preserve approval and execution state across reconnects;
- authorization and snapshot expiries are checked on every fresh execution.

### Sensitive logs and telemetry

Prompts, local observations, raw model reasoning, authentication material, images, health records, or tool arguments may leak through logs.

Controls:

- emit safe activity summaries, not chain-of-thought;
- redact known sensitive fields before display or telemetry;
- log IDs, event types, timing, status, and coarse error codes by default;
- make content logging opt-in, sampled, access-controlled, and time-limited;
- never commit keys, tokens, provisioning artifacts, raw user records, or production logs.

### Registry signing-key compromise

A stolen control-plane signing key could authorize malicious snapshots.

Controls:

- inject keys from a managed secret store and commit no private keys;
- pin trusted public keys in hosts, rotate with an overlap window, and support revocation;
- keep snapshot expiry short and reject stale revisions for writes;
- audit state changes and signing operations separately from model traffic.

Incident response: disable affected capabilities, revoke the public-key identifier, publish a higher revision signed by a trusted replacement key, invalidate cached snapshots, and inspect device receipts for affected writes.

### Unsafe or stale knowledge

Knowledge may be copyrighted, medically unsafe, uncited, expired, translated incorrectly, or unsuitable for a locale.

Controls:

- manifests require source ID, HTTPS URL, version, locale, reuse status, review time, citation policy, safety disclaimers, and review expiry;
- source authority, reuse permission, content review, and release approval are independent gates;
- evidence claims must cite passages returned by the current retrieval;
- unsupported medical advice and expired packs fail closed;
- missing reviewed evidence produces an admission, not a fabricated answer.

## Security invariants

1. Registry state narrows capability availability; it never grants user permission.
2. The model never directly executes a device tool.
3. A consequential write cannot execute without trusted identity, required scope, explicit confirmation, valid schema, and idempotency.
4. Reconnect and retry cannot create an additional committed write for the same idempotency key.
5. Evidence-marked answers cannot cite content that was not retrieved for that answer.
6. Domain data and product-specific renderers remain outside BeaconAgentKit.

## Verification expectations

Every security-sensitive change should include a failing regression test first. The release gate includes Python runtime tests, Swift package tests, JSON Schema tests, cross-language fixture replay, Foundation-only boundary tests, and host integration tests. Physical-device evidence remains the host application's responsibility for device-only permissions, signing, storage, and end-to-end writes.
