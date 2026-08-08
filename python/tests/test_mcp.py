from __future__ import annotations

import pytest

from beacon_agent_runtime.mcp import (
    MCPAdapterError,
    MCPPolicyProfile,
    MCPResource,
    MCPResourceResolver,
    MCPTool,
    MCPToolAdapter,
    MCPToolResult,
)


def policy() -> MCPPolicyProfile:
    return MCPPolicyProfile(
        capability_id="training.context.read",
        execution_location="device",
        risk="read_only",
        required_scopes=("training.read",),
        confirmation="never",
        idempotency="none",
        tags=("training",),
    )


def test_maps_schema_and_negotiated_app_metadata_without_trusting_annotations() -> None:
    tool = MCPTool(
        name="training_context",
        description="Read local context",
        inputSchema={"type": "object"},
        outputSchema={"type": "object"},
        annotations={"destructiveHint": True},
        _meta={"ui": {"resourceUri": "ui://jianhao/training"}},
    )

    manifest = MCPToolAdapter(mcp_apps_negotiated=True).capability_manifest(
        server_id="jianhao", tool=tool, policy=policy()
    )

    assert manifest.risk == "read_only"
    assert manifest.surface == "ui://jianhao/training"
    assert manifest.input_schema == {"type": "object"}


@pytest.mark.parametrize("name", ["shell.exec", "database.sql", "filesystem.read"])
def test_forbidden_generic_primitive_fails_closed(name: str) -> None:
    tool = MCPTool(name=name, description="unsafe", inputSchema={"type": "object"})
    with pytest.raises(MCPAdapterError, match="forbidden MCP tool"):
        MCPToolAdapter(mcp_apps_negotiated=True).capability_manifest(
            server_id="untrusted", tool=tool, policy=policy()
        )


def test_result_schema_redaction_a2ui_and_confirmation() -> None:
    tool = MCPTool(
        name="summary",
        description="Summary",
        inputSchema={"type": "object"},
        outputSchema={
            "type": "object",
            "required": ["summary"],
            "properties": {"summary": {"type": "string"}},
        },
    )
    result = MCPToolResult(
        content=({"type": "text", "text": "Call 13800138000"},),
        structuredContent={
            "summary": "token sk-123456789012345678901234",
            "a2ui": {
                "id": "surface-1",
                "revision": 1,
                "rootComponentID": "root",
                "status": "complete",
                "components": {
                    "root": {
                        "id": "root",
                        "type": "Text",
                        "properties": {"text": "完成"},
                        "children": [],
                        "actions": [],
                    }
                },
            },
        },
    )

    normalized = MCPToolAdapter(mcp_apps_negotiated=True).normalize_result(
        result=result, tool=tool, confirmation="always"
    )

    assert normalized.structured_content["summary"] == "token [REDACTED_API_KEY]"
    assert normalized.content[0]["text"] == "Call [REDACTED_PHONE]"
    assert normalized.a2ui["id"] == "surface-1"
    assert normalized.confirmation_required is True


def test_invalid_uri_oversized_and_unknown_resources_fail_closed() -> None:
    resolver = MCPResourceResolver(maximum_bytes=16)
    with pytest.raises(MCPAdapterError, match="invalid MCP Apps URI"):
        resolver.resolve(
            "https://example.com/app",
            (MCPResource(uri="https://example.com/app", mimeType="text/html", text="ok"),),
        )
    with pytest.raises(MCPAdapterError, match="resource exceeds"):
        resolver.resolve(
            "ui://jianhao/app",
            (MCPResource(
                uri="ui://jianhao/app",
                mimeType="text/html;profile=mcp-app",
                text="x" * 17,
            ),),
        )
    with pytest.raises(MCPAdapterError, match="resource not found"):
        resolver.resolve("ui://jianhao/missing", ())
