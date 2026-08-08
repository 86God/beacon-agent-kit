"""Signed control-plane snapshot and reference API tests."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi.testclient import TestClient

from beacon_agent_runtime.capabilities import CapabilityManifest, RegistrySnapshot
from beacon_agent_runtime.control_plane import InMemoryRegistryStore, create_control_plane_app
from beacon_agent_runtime.signing import sign_snapshot, verify_snapshot


def manifest(identifier: str = "training.context.read") -> CapabilityManifest:
    return CapabilityManifest(
        schemaVersion=2,
        id=identifier,
        version="1.0.0",
        kind="tool",
        title="Read training context",
        description="Reads minimum local context.",
        intentExamples=("Review my recent training",),
        inputSchema={"type": "object"},
        outputSchema={"type": "object"},
        executionLocation="device",
        risk="read_only",
        requiredScopes=("training.read",),
        confirmation="never",
        idempotency="none",
        dependencies=(),
        tags=("training", "context"),
        fallback="text_summary",
        offlineSafe=True,
    )


def unsigned_snapshot() -> RegistrySnapshot:
    now = datetime.now(UTC)
    return RegistrySnapshot.create(
        revision="registry-1",
        environment="development",
        issued_at=now,
        expires_at=now + timedelta(minutes=5),
        manifests=(manifest(),),
        signature="unsigned",
    )


def test_ed25519_snapshot_signing_rejects_tampering() -> None:
    private_key = Ed25519PrivateKey.generate()
    signed = sign_snapshot(unsigned_snapshot(), private_key)

    verify_snapshot(signed, private_key.public_key())
    tampered = signed.model_copy(update={"revision": "registry-tampered"})
    with pytest.raises(InvalidSignature):
        verify_snapshot(tampered, private_key.public_key())


def test_control_plane_lists_toggles_and_publishes_signed_snapshots() -> None:
    private_key = Ed25519PrivateKey.generate()
    store = InMemoryRegistryStore((manifest(),))
    client = TestClient(create_control_plane_app(store=store, private_key=private_key))

    listed = client.get("/v1/capabilities", params={"environment": "development"})
    assert listed.status_code == 200
    assert listed.json()["revision"] == "development-0"
    assert listed.json()["capabilities"][0]["enabled"] is False

    changed = client.put(
        "/v1/capabilities/training.context.read/state",
        json={"environment": "development", "enabled": True},
    )
    assert changed.status_code == 200
    assert changed.json() == {
        "capabilityId": "training.context.read",
        "enabled": True,
        "environment": "development",
        "revision": "development-1",
    }

    response = client.get(
        "/v1/registry/snapshot",
        params={"environment": "development"},
    )
    assert response.status_code == 200
    signed = RegistrySnapshot.model_validate(response.json())
    assert signed.revision == "development-1"
    assert [item.id for item in signed.manifests] == ["training.context.read"]
    verify_snapshot(signed, private_key.public_key())


def test_control_plane_rejects_unknown_ids_invalid_payloads_and_permission_grants() -> None:
    client = TestClient(
        create_control_plane_app(
            store=InMemoryRegistryStore((manifest(),)),
            private_key=Ed25519PrivateKey.generate(),
        )
    )

    assert client.put(
        "/v1/capabilities/unknown.capability/state",
        json={"environment": "development", "enabled": True},
    ).status_code == 404
    assert client.put(
        "/v1/capabilities/training.context.read/state",
        json={
            "environment": "development",
            "enabled": True,
            "authorizedScopes": ["training.read"],
        },
    ).status_code == 422
    assert client.get(
        "/v1/registry/snapshot",
        params={"environment": "unknown"},
    ).status_code == 422

