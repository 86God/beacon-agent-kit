"""Domain-neutral reference runtime for BeaconAgentKit."""

from .protocol import (
    AgentEvent,
    AgentEventType,
    AgentWireValidationError,
    UnsupportedSchemaVersionError,
    parse_agent_event,
)
from .negotiation import (
    ProtocolFailure,
    ProtocolNegotiationResult,
    ProtocolPublicError,
    negotiate_protocol_version,
)

__all__ = [
    "AgentEvent",
    "AgentEventType",
    "AgentWireValidationError",
    "UnsupportedSchemaVersionError",
    "parse_agent_event",
    "ProtocolFailure",
    "ProtocolNegotiationResult",
    "ProtocolPublicError",
    "negotiate_protocol_version",
]
