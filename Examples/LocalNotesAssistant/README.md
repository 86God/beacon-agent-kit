# LocalNotesAssistant

This standalone Swift package proves that an app outside JianHao can consume
BeaconAgentKit without importing JianHao, HealthKit, SwiftUI, UIKit, or fitness
domain types.

The example implements one narrow workflow:

```text
prompt -> notes.read -> notes.draft -> approval.requested
       -> user confirms -> notes.commit -> receipt.committed -> run.finished
```

`BeaconDeviceToolDispatcher` owns scope, schema, account, expiry, confirmation,
and in-flight checks. `BeaconRunJournal` owns ordered events and the durable
approval outbox. `BeaconMemoryFileRepository` stores only a post-confirmation
continuity memory. The example owns its note schema and atomic local note store;
it does not copy the SDK reducer or run state machine.

## Verify

```bash
swift test
```

The test starts a draft, recreates the session from disk before confirmation,
confirms the restored draft, recreates the session again, and verifies the
terminal projection, note, receipt cleanup, event order, and authorized memory.
It also scans reusable SDK sources for forbidden product and health UI imports.

## Run

```bash
swift run local-notes-assistant "Buy oats and blueberries"
```

The CLI writes only after an explicit `y` confirmation. Its sample model is a
local deterministic adapter; it makes no network request. Runtime files are
stored under `.local-notes-assistant/` in the current directory and should not
be committed.
