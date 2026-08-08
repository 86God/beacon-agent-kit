"""Minimal reference control plane for capability enablement and snapshots."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from threading import Lock
from typing import Protocol

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel, ConfigDict

from .capabilities import (
    CapabilityManifest,
    RegistryEnvironment,
    RegistrySnapshot,
)
from .signing import sign_snapshot


class RegistryStore(Protocol):
    def list_manifests(self) -> tuple[CapabilityManifest, ...]: ...

    def is_enabled(self, environment: RegistryEnvironment, capability_id: str) -> bool: ...

    def set_enabled(
        self,
        environment: RegistryEnvironment,
        capability_id: str,
        enabled: bool,
    ) -> str: ...

    def revision(self, environment: RegistryEnvironment) -> str: ...


class InMemoryRegistryStore:
    """Deterministic test/reference store; production adapters implement RegistryStore."""

    def __init__(self, manifests: tuple[CapabilityManifest, ...]) -> None:
        identifiers = [item.id for item in manifests]
        if len(identifiers) != len(set(identifiers)):
            raise ValueError("duplicate capability IDs")
        self._manifests = {item.id: item for item in manifests}
        self._enabled: dict[RegistryEnvironment, set[str]] = {
            environment: set() for environment in RegistryEnvironment
        }
        self._revisions: dict[RegistryEnvironment, int] = {
            environment: 0 for environment in RegistryEnvironment
        }
        self._lock = Lock()

    def list_manifests(self) -> tuple[CapabilityManifest, ...]:
        return tuple(sorted(self._manifests.values(), key=lambda item: item.id))

    def is_enabled(self, environment: RegistryEnvironment, capability_id: str) -> bool:
        return capability_id in self._enabled[environment]

    def set_enabled(
        self,
        environment: RegistryEnvironment,
        capability_id: str,
        enabled: bool,
    ) -> str:
        if capability_id not in self._manifests:
            raise KeyError(capability_id)
        with self._lock:
            before = capability_id in self._enabled[environment]
            if enabled:
                self._enabled[environment].add(capability_id)
            else:
                self._enabled[environment].discard(capability_id)
            if before != enabled:
                self._revisions[environment] += 1
            return self.revision(environment)

    def revision(self, environment: RegistryEnvironment) -> str:
        return f"{environment.value}-{self._revisions[environment]}"


class CapabilityStateUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    environment: RegistryEnvironment
    enabled: bool


def create_control_plane_app(
    *,
    store: RegistryStore,
    private_key: Ed25519PrivateKey,
    snapshot_ttl: timedelta = timedelta(minutes=5),
) -> FastAPI:
    app = FastAPI(title="BeaconAgentKit Control Plane", version="0.2.0")

    @app.get("/v1/capabilities")
    def list_capabilities(
        environment: RegistryEnvironment = Query(default=RegistryEnvironment.DEVELOPMENT),
    ) -> dict[str, object]:
        return {
            "environment": environment.value,
            "revision": store.revision(environment),
            "capabilities": [
                {
                    "manifest": item.model_dump(by_alias=True, mode="json"),
                    "enabled": store.is_enabled(environment, item.id),
                }
                for item in store.list_manifests()
            ],
        }

    @app.put("/v1/capabilities/{capability_id}/state")
    def update_capability_state(
        capability_id: str,
        update: CapabilityStateUpdate,
    ) -> dict[str, object]:
        try:
            revision = store.set_enabled(update.environment, capability_id, update.enabled)
        except KeyError as error:
            raise HTTPException(status_code=404, detail="Unknown capability ID") from error
        return {
            "capabilityId": capability_id,
            "enabled": update.enabled,
            "environment": update.environment.value,
            "revision": revision,
        }

    @app.get("/v1/registry/snapshot")
    def registry_snapshot(
        environment: RegistryEnvironment = Query(...),
    ) -> dict[str, object]:
        issued_at = datetime.now(UTC)
        manifests = tuple(
            item
            for item in store.list_manifests()
            if store.is_enabled(environment, item.id)
        )
        unsigned = RegistrySnapshot.create(
            revision=store.revision(environment),
            environment=environment,
            issued_at=issued_at,
            expires_at=issued_at + snapshot_ttl,
            manifests=manifests,
            signature="unsigned",
        )
        signed = sign_snapshot(unsigned, private_key)
        return signed.model_dump(by_alias=True, mode="json")

    return app
