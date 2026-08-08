# Security Policy

## Supported versions

BeaconAgentKit v0.2 is pre-release software. Security fixes are made on the active default branch and the latest tagged release once public releases begin. Older alpha snapshots are not guaranteed to receive backports.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability involving authorization bypass, cross-account access, duplicate writes, registry signing, sensitive logging, prompt or MCP injection, unsafe knowledge, or remote code execution.

Report it privately to the repository maintainer through the security contact configured on the repository hosting service. Include:

- affected commit or version;
- minimal reproduction and expected behavior;
- whether a real account, device, registry key, or user record was involved;
- logs with secrets and personal data removed;
- suggested mitigation, if known.

Do not include API keys, signing identities, provisioning profiles, raw health records, images, prompts containing private data, or production registry private keys.

## Maintainer response

Maintainers should acknowledge a complete report, reproduce it in an isolated environment, assign severity, and coordinate a fix and disclosure. Affected capabilities should be disabled when a live exploit could cause unauthorized reads or writes. Registry signing-key incidents additionally require key revocation and snapshot invalidation.

## Deployment responsibilities

Adopters are responsible for their model provider, transport security, secret storage, user authentication, device permissions, local persistence, application privacy disclosures, and final tool handlers. BeaconAgentKit's control plane cannot grant device permission and must not be treated as an authorization service for user data.

See [docs/threat-model.md](docs/threat-model.md) for trust boundaries, controls, and residual risks.
