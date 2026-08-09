"""Fail-closed resolution of one immutable effective capability registry."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime

from .capabilities import (
    CapabilityManifest,
    DeviceCapabilityAdvertisement,
    RegistrySnapshot,
)


class RegistryError(ValueError):
    pass


class RegistryExpiredError(RegistryError):
    pass


class DuplicateCapabilityError(RegistryError):
    pass


class RegistryDependencyCycleError(RegistryError):
    pass


@dataclass(frozen=True)
class EffectiveRegistry:
    revision: str
    capabilities: tuple[CapabilityManifest, ...]


class CapabilityRegistry:
    def __init__(self, snapshot: RegistrySnapshot) -> None:
        self.snapshot = snapshot
        identifiers = [item.id for item in snapshot.manifests]
        if len(identifiers) != len(set(identifiers)):
            raise DuplicateCapabilityError("duplicate capability IDs")
        self._manifests = {item.id: item for item in snapshot.manifests}
        self._reject_dependency_cycles()

    def resolve(
        self,
        *,
        server_enabled: set[str],
        authorized_scopes: set[str],
        policy_allowed: set[str],
        device_advertisements: tuple[DeviceCapabilityAdvertisement, ...] = (),
        host_advertised: set[str] | None = None,
        compatible: set[str] | None = None,
        now: datetime | None = None,
    ) -> EffectiveRegistry:
        current = now or datetime.now(UTC)
        if current >= self.snapshot.expires_at:
            raise RegistryExpiredError("registry snapshot expired")
        if device_advertisements:
            advertisements = {
                advertisement.capability_id: advertisement
                for advertisement in device_advertisements
            }
            device_compatible = {
                manifest.id
                for manifest in self.snapshot.manifests
                if (advertisement := advertisements.get(manifest.id)) is not None
                and advertisement.enabled
                and advertisement.version == manifest.version
                and manifest.schema_version in advertisement.supported_schema_versions
            }
        else:
            # Compatibility with the pre-advertisement protocol while callers
            # are migrated.  New hosts must send `device_advertisements`.
            device_compatible = (host_advertised or set()) & (compatible or set())
        allowed_ids = server_enabled & device_compatible & policy_allowed
        capabilities = tuple(
            item
            for item in sorted(self.snapshot.manifests, key=lambda capability: capability.id)
            if item.id in allowed_ids and set(item.required_scopes) <= authorized_scopes
        )
        return EffectiveRegistry(revision=self.snapshot.revision, capabilities=capabilities)

    def _reject_dependency_cycles(self) -> None:
        graph = {
            identifier: {
                dependency.split("@", 1)[0]
                for dependency in manifest.dependencies
                if dependency.split("@", 1)[0] in self._manifests
            }
            for identifier, manifest in self._manifests.items()
        }
        visiting: set[str] = set()
        visited: set[str] = set()

        def visit(identifier: str) -> None:
            if identifier in visiting:
                raise RegistryDependencyCycleError("capability dependency cycle")
            if identifier in visited:
                return
            visiting.add(identifier)
            for dependency in graph[identifier]:
                visit(dependency)
            visiting.remove(identifier)
            visited.add(identifier)

        for identifier in graph:
            visit(identifier)
