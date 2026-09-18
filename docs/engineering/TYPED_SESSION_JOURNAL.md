# Typed session event journal

> Historical engineering record. The current session contract is [AGENT_SESSION_LOG](../architecture/AGENT_SESSION_LOG.md). This file is retained only for prior format decisions and measurements; its draft, external-body, retention, and request-manifest descriptions do not define the current implementation.

The current reader and writer use DSH v3 semantic events, immutable inline session content, process-local streams until settlement, and Mira physical commit frames. See [authoritative session reads](../architecture/AGENT_SESSION_READS.md) for reconstruction, recovery, audit, and projection boundaries.
