"""Ed25519 signing for canonical registry snapshots."""

from __future__ import annotations

import base64
import json

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)

from .capabilities import RegistrySnapshot


def snapshot_signing_payload(snapshot: RegistrySnapshot) -> bytes:
    document = snapshot.model_dump(by_alias=True, mode="json", exclude={"signature"})
    return json.dumps(
        document,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def sign_snapshot(
    snapshot: RegistrySnapshot,
    private_key: Ed25519PrivateKey,
) -> RegistrySnapshot:
    signature = private_key.sign(snapshot_signing_payload(snapshot))
    encoded = base64.urlsafe_b64encode(signature).decode("ascii").rstrip("=")
    return snapshot.model_copy(update={"signature": encoded})


def verify_snapshot(
    snapshot: RegistrySnapshot,
    public_key: Ed25519PublicKey,
) -> None:
    padding = "=" * (-len(snapshot.signature) % 4)
    signature = base64.urlsafe_b64decode(snapshot.signature + padding)
    public_key.verify(signature, snapshot_signing_payload(snapshot))
