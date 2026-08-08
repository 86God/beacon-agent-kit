# Contributing to BeaconAgentKit

## Development setup

Required tools:

- Swift 6 toolchain;
- Python 3.12 or newer;
- a virtual environment with the Python test extra.

```bash
python3 -m venv .venv
.venv/bin/pip install -e './python[test]'
.venv/bin/python -m pytest python/tests -q
swift test
```

## Change workflow

1. Open an issue or focused proposal for changes to public schemas or trust boundaries.
2. Add a failing test that captures the intended behavior.
3. Implement the smallest provider-neutral change.
4. Run the relevant targeted tests, then both complete suites.
5. Update schemas, conformance fixtures, examples, architecture, and threat model when their contract changes.

Keep commits narrow and do not mix generated artifacts, signing state, keys, or product-specific code into framework changes.

## Architectural boundaries

- `BeaconAgentCore` is Foundation-only.
- BeaconAgentKit owns protocols, immutable manifests, policy, runtime events, generic surfaces, and adapters.
- Host apps own domain models, identity, permissions, local data, product prompts, mutations, and product-specific renderers.
- The server can disable capabilities, but cannot grant access to device data.
- Model output, MCP metadata, retrieved content, and remote manifests are untrusted.
- Consequential writes require host authorization, confirmation, validation, and idempotency.

Do not add a model-provider SDK or a product backend client to core modules. Integrations belong behind protocols or in separate packages.

## Compatibility

Wire schemas use explicit versions. Adding a required field or changing meaning requires a new schema version and cross-language fixtures. Readers must reject unsupported required versions and may preserve explicitly extensible unknown events.

## Security and privacy

Follow [SECURITY.md](SECURITY.md) and [docs/threat-model.md](docs/threat-model.md). Tests and examples must use synthetic data. Never commit secrets, private keys, provisioning profiles, production logs, or real user records.
