# Device Tool Loop Example

This domain-neutral example shows a local task assistant with two tools:

- `tasks.list`: read local tasks;
- `tasks.create`: draft and, after approval, commit one local task.

The server hosts the registry, routing, model call, and bounded Agent loop. The host app advertises compatible tools, owns identity and permission, executes local handlers, renders the draft surface, and persists the confirmed task. No user task data needs to be stored by the control plane.

## Capability manifests

```json
{
  "id": "tasks.list",
  "kind": "tool",
  "risk": "read_only",
  "executionLocation": "device",
  "requiredScopes": ["tasks.read"],
  "inputSchema": {
    "type": "object",
    "additionalProperties": false,
    "properties": {"day": {"type": "string", "format": "date"}},
    "required": ["day"]
  },
  "outputSchema": {"type": "object"}
}
```

`tasks.create` uses the same device execution location, declares `consequential_write`, requires `tasks.write`, and requires confirmation and an idempotency key. A workflow manifest composes the read and write tools and advertises the surface type `task.draft@1`.

## Runtime sequence

```text
user: "Add a task tomorrow to call Sam"
router: resolves tomorrow and selects the task workflow
model -> tasks.list(day=tomorrow)
runtime -> device tool interrupt
host -> local observation
model -> task draft
runtime -> surface.start(task.draft@1)
runtime -> surface.patch(title="Call Sam", date=tomorrow)
host -> editable native surface
user -> confirm
runtime -> approval interrupt/resume
model -> tasks.create(title="Call Sam", day=tomorrow, idempotencyKey=stable-key)
host -> validate trusted account, scope, confirmation, schema, expiry
host -> commit once and return receipt
model -> finish
```

## Host sketch

```swift
let advertisement = BeaconDeviceCapabilityAdvertisement(
    capabilityID: "tasks.create",
    schemaVersion: 2,
    supportedScopes: ["tasks.write"]
)

let dispatcher = BeaconDeviceToolDispatcher(
    handlers: [TaskListHandler(store: store), TaskCreateHandler(store: store)],
    policy: policy,
    receiptStore: receiptStore
)

// Trusted identity and granted scopes come from the signed-in host, never request arguments.
let observation = try await dispatcher.dispatch(
    request,
    authorization: trustedHostContext
)
```

The renderer registers `task.draft@1` in `BeaconSurfaceRendererCatalog`. `surface.start` creates a stable surface ID immediately; later patches update title, date, validation, and write state in place. Unknown surface types fall back to a safe generic view and never execute actions automatically.

On retry, `tasks.create` reuses the original idempotency key. The device dispatcher returns the completed receipt instead of calling `TaskCreateHandler` again. The host then reads tomorrow's local tasks to verify the write.
