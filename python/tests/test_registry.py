"""Capability manifest and effective-registry policy tests."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest
from pydantic import ValidationError

from beacon_agent_runtime.capabilities import (
    CapabilityManifest,
    DeviceCapabilityAdvertisement,
    RegistrySnapshot,
    canonical_manifest_json,
)
from beacon_agent_runtime.registry import (
    CapabilityRegistry,
    DuplicateCapabilityError,
    RegistryDependencyCycleError,
    RegistryExpiredError,
)


def manifest(
    identifier: str = "training.plan.draft",
    *,
    dependencies: tuple[str, ...] = (),
    scopes: tuple[str, ...] = ("training.read", "training.draft.write"),
) -> CapabilityManifest:
    return CapabilityManifest(
        schemaVersion=2,
        id=identifier,
        version="1.0.0",
        kind="workflow",
        title="Draft training plan",
        description="Creates a reversible local draft.",
        intentExamples=("Arrange shoulder training tomorrow",),
        inputSchema={"type": "object"},
        outputSchema={"type": "object"},
        executionLocation="device",
        risk="reversible_draft",
        requiredScopes=scopes,
        confirmation="before_commit",
        idempotency="required",
        dependencies=dependencies,
        surface="training.plan.draft@^1",
        tags=("training", "shoulder"),
        fallback="text_summary",
    )


def snapshot(*manifests: CapabilityManifest, expired: bool = False) -> RegistrySnapshot:
    now = datetime.now(UTC)
    return RegistrySnapshot.create(
        revision="registry-1",
        environment="development",
        issued_at=now - timedelta(minutes=1),
        expires_at=now - timedelta(seconds=1) if expired else now + timedelta(minutes=5),
        manifests=manifests,
        signature="unsigned-test-fixture",
    )


def test_effective_registry_is_strict_intersection() -> None:
    plan = manifest()
    registry = CapabilityRegistry(snapshot(plan))

    effective = registry.resolve(
        server_enabled={"training.plan.draft"},
        host_advertised={"training.plan.draft", "sleep.summary"},
        compatible={"training.plan.draft"},
        authorized_scopes={"training.read", "training.draft.write"},
        policy_allowed={"training.plan.draft"},
    )

    assert [item.id for item in effective.capabilities] == ["training.plan.draft"]


@pytest.mark.parametrize(
    "override",
    [
        {"server_enabled": set()},
        {"host_advertised": set()},
        {"compatible": set()},
        {"authorized_scopes": {"training.read"}},
        {"policy_allowed": set()},
    ],
)
def test_disabled_absent_incompatible_unauthorized_or_denied_is_removed(
    override: dict[str, set[str]],
) -> None:
    plan = manifest()
    registry = CapabilityRegistry(snapshot(plan))
    arguments = {
        "server_enabled": {plan.id},
        "host_advertised": {plan.id},
        "compatible": {plan.id},
        "authorized_scopes": set(plan.required_scopes),
        "policy_allowed": {plan.id},
    }
    arguments.update(override)

    assert registry.resolve(**arguments).capabilities == ()


def test_expired_snapshot_fails_closed() -> None:
    plan = manifest()
    registry = CapabilityRegistry(snapshot(plan, expired=True))

    with pytest.raises(RegistryExpiredError):
        registry.resolve(
            server_enabled={plan.id},
            host_advertised={plan.id},
            compatible={plan.id},
            authorized_scopes=set(plan.required_scopes),
            policy_allowed={plan.id},
        )


def test_duplicate_manifest_fails_closed() -> None:
    plan = manifest()

    with pytest.raises(DuplicateCapabilityError):
        CapabilityRegistry(snapshot(plan, plan))


def test_dependency_cycle_fails_closed() -> None:
    first = manifest("example.first", dependencies=("example.second@^1",))
    second = manifest("example.second", dependencies=("example.first@^1",))

    with pytest.raises(RegistryDependencyCycleError):
        CapabilityRegistry(snapshot(first, second))


def test_manifest_and_snapshot_are_immutable_and_hashes_are_canonical() -> None:
    plan = manifest()
    registry_snapshot = snapshot(plan)
    reordered = dict(reversed(list(plan.model_dump(by_alias=True, mode="json").items())))

    assert canonical_manifest_json(plan) == canonical_manifest_json(reordered)
    assert registry_snapshot.manifest_hashes[plan.id]
    with pytest.raises(ValidationError):
        plan.title = "mutated"  # type: ignore[misc]


def test_effective_registry_requires_enabled_matching_device_advertisement() -> None:
    plan = manifest()
    registry = CapabilityRegistry(snapshot(plan))

    effective = registry.resolve(
        server_enabled={plan.id},
        device_advertisements=(
            DeviceCapabilityAdvertisement(
                capabilityId=plan.id,
                version=plan.version,
                supportedSchemaVersions={plan.schema_version},
                enabled=True,
            ),
        ),
        authorized_scopes=set(plan.required_scopes),
        policy_allowed={plan.id},
    )

    assert [item.id for item in effective.capabilities] == [plan.id]

    for incompatible_advertisement in (
        DeviceCapabilityAdvertisement(
            capabilityId=plan.id,
            version="2.0.0",
            supportedSchemaVersions={plan.schema_version},
            enabled=True,
        ),
        DeviceCapabilityAdvertisement(
            capabilityId=plan.id,
            version=plan.version,
            supportedSchemaVersions={1},
            enabled=True,
        ),
        DeviceCapabilityAdvertisement(
            capabilityId=plan.id,
            version=plan.version,
            supportedSchemaVersions={plan.schema_version},
            enabled=False,
        ),
    ):
        assert registry.resolve(
            server_enabled={plan.id},
            device_advertisements=(incompatible_advertisement,),
            authorized_scopes=set(plan.required_scopes),
            policy_allowed={plan.id},
        ).capabilities == ()
