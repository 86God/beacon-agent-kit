"""Safe runtime selection for incremental LangGraph migration."""

from beacon_agent_runtime.native_langgraph_runtime import NativeLangGraphAgentRuntime
from beacon_agent_runtime.runtime import AgentRuntime
from beacon_agent_runtime.runtime_selector import RuntimeMode, select_runtime


def test_runtime_selector_has_reversible_primary_and_nonwriting_shadow_mode() -> None:
    assert select_runtime(RuntimeMode.LEGACY).primary is AgentRuntime
    assert select_runtime(RuntimeMode.LANGGRAPH).primary is NativeLangGraphAgentRuntime

    shadow = select_runtime(RuntimeMode.SHADOW_COMPARE)
    assert shadow.primary is NativeLangGraphAgentRuntime
    assert shadow.shadow is AgentRuntime
