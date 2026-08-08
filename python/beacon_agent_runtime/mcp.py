"""Fail-closed adapters for MCP tools, results, resources, and MCP Apps metadata."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlparse

from jsonschema import Draft202012Validator, ValidationError
from pydantic import BaseModel, ConfigDict, Field

from .capabilities import CapabilityManifest


class MCPAdapterError(ValueError):
    pass


class MCPTool(BaseModel):
    model_config = ConfigDict(populate_by_name=True, frozen=True, extra="forbid")

    name: str
    title: str | None = None
    description: str
    input_schema: dict[str, Any] = Field(alias="inputSchema")
    output_schema: dict[str, Any] | None = Field(alias="outputSchema", default=None)
    annotations: dict[str, Any] = {}
    metadata: dict[str, Any] = Field(alias="_meta", default={})


@dataclass(frozen=True)
class MCPPolicyProfile:
    capability_id: str
    execution_location: str
    risk: str
    required_scopes: tuple[str, ...]
    confirmation: str
    idempotency: str
    tags: tuple[str, ...]


class MCPToolResult(BaseModel):
    model_config = ConfigDict(populate_by_name=True, frozen=True, extra="forbid")

    content: tuple[dict[str, Any], ...] = ()
    structured_content: dict[str, Any] = Field(alias="structuredContent", default={})
    is_error: bool = Field(alias="isError", default=False)


@dataclass(frozen=True)
class NormalizedMCPResult:
    content: tuple[dict[str, Any], ...]
    structured_content: dict[str, Any]
    a2ui: dict[str, Any] | None
    confirmation_required: bool
    is_error: bool


class MCPResource(BaseModel):
    model_config = ConfigDict(populate_by_name=True, frozen=True, extra="forbid")

    uri: str
    mime_type: str = Field(alias="mimeType")
    text: str | None = None
    blob: bytes | None = None


class MCPToolAdapter:
    _forbidden = {"shell", "terminal", "exec", "command", "sql", "filesystem", "file", "fs"}

    def __init__(self, *, mcp_apps_negotiated: bool) -> None:
        self.mcp_apps_negotiated = mcp_apps_negotiated

    def capability_manifest(
        self, *, server_id: str, tool: MCPTool, policy: MCPPolicyProfile
    ) -> CapabilityManifest:
        if not server_id.strip() or not tool.name.strip() or not tool.description.strip():
            raise MCPAdapterError("invalid MCP tool")
        tokens = set(filter(None, re.split(r"[^a-z0-9]+", tool.name.lower())))
        if tokens & self._forbidden:
            raise MCPAdapterError(f"forbidden MCP tool: {tool.name}")
        resource_uri = self._resource_uri(tool.metadata)
        return CapabilityManifest(
            schemaVersion=2,
            id=policy.capability_id,
            version="1.0.0",
            kind="tool",
            title=tool.title or tool.name,
            description=tool.description,
            intentExamples=(tool.description,),
            inputSchema=tool.input_schema,
            outputSchema=tool.output_schema or {"type": "object"},
            executionLocation=policy.execution_location,
            risk=policy.risk,
            requiredScopes=policy.required_scopes,
            confirmation=policy.confirmation,
            idempotency=policy.idempotency,
            dependencies=(),
            surface=resource_uri if self.mcp_apps_negotiated else None,
            tags=policy.tags + ("mcp", f"mcp.server.{server_id}"),
            fallback="text_summary",
        )

    def normalize_result(
        self, *, result: MCPToolResult, tool: MCPTool, confirmation: str
    ) -> NormalizedMCPResult:
        structured = _redact(result.structured_content)
        if tool.output_schema is not None:
            try:
                Draft202012Validator(tool.output_schema).validate(structured)
            except ValidationError as error:
                raise MCPAdapterError("invalid structured MCP result") from error
        content = tuple(_redact(item) for item in result.content)
        a2ui = structured.get("a2ui")
        if a2ui is not None:
            _validate_a2ui(a2ui)
        return NormalizedMCPResult(
            content=content,
            structured_content=structured,
            a2ui=a2ui,
            confirmation_required=confirmation != "never",
            is_error=result.is_error,
        )

    @staticmethod
    def _resource_uri(metadata: dict[str, Any]) -> str | None:
        nested = metadata.get("ui")
        value = nested.get("resourceUri") if isinstance(nested, dict) else None
        value = value if value is not None else metadata.get("ui/resourceUri")
        if value is None:
            return None
        if not isinstance(value, str) or not _valid_ui_uri(value):
            raise MCPAdapterError(f"invalid MCP Apps URI: {value}")
        return value


class MCPResourceResolver:
    def __init__(self, *, maximum_bytes: int = 262_144) -> None:
        self.maximum_bytes = maximum_bytes

    def resolve(self, requested_uri: str, resources: tuple[MCPResource, ...]) -> MCPResource:
        if not _valid_ui_uri(requested_uri):
            raise MCPAdapterError(f"invalid MCP Apps URI: {requested_uri}")
        resource = next((item for item in resources if item.uri == requested_uri), None)
        if resource is None:
            raise MCPAdapterError(f"resource not found: {requested_uri}")
        if resource.mime_type.lower() != "text/html;profile=mcp-app":
            raise MCPAdapterError(f"invalid MCP Apps MIME type: {resource.mime_type}")
        size = len(resource.text.encode("utf-8")) if resource.text is not None else len(resource.blob or b"")
        if size > self.maximum_bytes:
            raise MCPAdapterError(f"resource exceeds safe limit: {requested_uri}")
        return resource


def _valid_ui_uri(value: str) -> bool:
    parsed = urlparse(value)
    return parsed.scheme == "ui" and bool(parsed.netloc)


def _redact(value: Any) -> Any:
    if isinstance(value, str):
        value = re.sub(r"\bsk-[A-Za-z0-9_-]{20,}\b", "[REDACTED_API_KEY]", value)
        return re.sub(r"(?<!\d)1[3-9]\d{9}(?!\d)", "[REDACTED_PHONE]", value)
    if isinstance(value, dict):
        return {key: _redact(child) for key, child in value.items()}
    if isinstance(value, (list, tuple)):
        return type(value)(_redact(child) for child in value)
    return value


def _validate_a2ui(surface: Any) -> None:
    if not isinstance(surface, dict):
        raise MCPAdapterError("invalid embedded A2UI surface")
    components = surface.get("components")
    root = surface.get("rootComponentID")
    if not isinstance(components, dict) or root not in components:
        raise MCPAdapterError("invalid embedded A2UI surface")
    allowed_components = {
        "Text", "Row", "Column", "Card", "Button", "Metric", "List", "Table",
        "Notice", "Error", "Retry", "Approval", "Receipt",
    }
    allowed_actions = {
        "submit", "cancel", "retry", "approve", "reject", "replace",
        "increment", "decrement", "reorder", "select",
    }
    identity_keys = {"userid", "accountid", "deviceid", "accountscope", "authorizedscopes", "permissionstate", "databasepath"}
    for identifier, component in components.items():
        if not isinstance(component, dict) or component.get("id") != identifier:
            raise MCPAdapterError("invalid embedded A2UI surface")
        if component.get("type") not in allowed_components:
            raise MCPAdapterError("invalid embedded A2UI surface")
        if any(child not in components for child in component.get("children", ())):
            raise MCPAdapterError("invalid embedded A2UI surface")
        if any(action.get("name") not in allowed_actions for action in component.get("actions", ())):
            raise MCPAdapterError("invalid embedded A2UI surface")
        keys = {key.lower() for key in _nested_keys(component)}
        if keys & identity_keys:
            raise MCPAdapterError("invalid embedded A2UI surface")


def _nested_keys(value: Any):
    if isinstance(value, dict):
        for key, child in value.items():
            yield str(key)
            yield from _nested_keys(child)
    elif isinstance(value, list):
        for child in value:
            yield from _nested_keys(child)
