# Reference control plane

The reference service is created with `create_control_plane_app(store:, private_key:)`.
It deliberately keeps persistence and key management behind injected interfaces:

- `RegistryStore` owns manifests, enablement, and monotonically increasing revisions.
- The caller injects an Ed25519 private key; no key material belongs in this repository.
- Enablement only makes a capability eligible for later intersection. It does not grant
  user scopes, device permissions, confirmation, or account ownership.
- Snapshots are short-lived, contain canonical manifest hashes, and are signed over all
  fields except `signature`.

`InMemoryRegistryStore` exists for tests and examples. Production deployments should
replace it with transactional storage and managed key custody without changing the API.
