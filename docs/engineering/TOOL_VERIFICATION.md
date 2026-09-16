# Production tool verification

Historical verification of the tool fixes. The later automatic-memory implementation changes standard saved memories to allow recall; sensitive memories remain local-only. See `LOCAL_MEMORY_IMPLEMENTATION.md` for the current policy.

Date: 2026-09-15. Baseline: `543a6f5`. Branch: `codex/tool-verification`.

## Findings and corrections

### 1. All eight production tools rejected ordinary inherited context

The executor merged model-request sources into `AgentToolPlan.sources`. Domain validators interpret that field as the tool's own reads: memory/task writes require it to be empty; readers require their own namespaces and bounded result counts. Consequently a prior conversation turn or recalled memory caused legitimate calls to be denied.

`ProductionToolWorkflowTests` reproduced all eight tools returning `denied` with no result before the correction. The fixture uses real journal admission, all three production domain modules, SQLite domain validators, a prior completed conversation, and a remote-authorized synthetic memory. It checks actual result content, durable write receipts, and the exact result delivered to the next model step.

The proposal now stores inherited model context separately from the tool-owned plan. The executor authorizes the complete union at dispatch/publication gates. Journal proof resolution checks exact inherited-source equality. Continuation and privacy maintenance retain the union. Tests also reject inherited-source revocation at three pre-write checkpoints and forged missing/extra inherited dependencies.

| Tool | Verified useful result |
| --- | --- |
| `memory.search` | Authorized stored memory content |
| `memory.get` | Exact identified memory content |
| `memory.remember` | Committed local-only memory and business receipt |
| `knowledge.search` | Imported Markdown chunk match |
| `source.open` | Source title and bounded metadata |
| `source.read_chunk` | Exact imported chunk body |
| `task.list` | Persisted task ID and summary |
| `task.change` | Created task, saved-result flag and business receipt |

### 2. Task list → mutation failed after committing the change

An exact-current-revision source check rejected the original list's revision once the mutation created a newer revision. A controlled rerun with the original `TaskSourceAuthority` reproduced failed final executions for complete, update, and cancel, even though their task changes and receipts were committed.

Task context authority now resolves an exact retained immutable revision while checking the current task/workspace in the same SQLite snapshot. Mutation preparation and commit retain exact current-revision CAS. The sequence tests check complete/update/cancel receipts, completed final replies, preserved original provenance, stale-target rejection, and lookup beyond the latest 100 revisions. Wrong workspaces and missing revisions remain rejected.

### 3. Responses protocol boundaries

- Function definitions explicitly preserve non-strict optional parameters. Tests use the real task-change and source-open schemas and valid omitted arguments. The [official guide](https://developers.openai.com/api/docs/guides/function-calling#strict-mode) documents automatic strict normalization when this flag is omitted; this is a request-contract correction, not a measured live-provider failure rate.
- Terminal output items may omit status after their done event. Thinking, text, function calls, usage and hidden continuation survive that shape. Missing completion boundaries, invalid status types and contradictory incomplete states remain errors.
- SSE `error` events map to a safe provider rejection instead of being ignored until EOF. Raw provider error content is not retained.

Chat Completions and Anthropic tool encoding/continuation were reviewed; no additional definite defect was identified. Their affected contract and thinking regressions are included in acceptance.

## Verification evidence

- Package acceptance: **206 tests in 25 suites passed**. Selected suites cover the eight-tool workflow, task sequences/integrity, tool execution/evidence/policies, memory/knowledge modules and workflows, journal proof/receipts, privacy, session state, model execution/recovery, Responses, HTTP adapter contracts/failures, and HTTP application integration. This was not the full package suite.
- Separate thinking continuation checks: **7 tests passed**, selected by their actual top-level test functions (`anthropicOrderedThinkingReplay`, `anthropicIncompleteThinkingBeforeToolCalls`, `openRouterLargeReasoningDetails`, `partialReasoningPrematureEOF`, `thinkingPayloadTable`, `conflictingOpenRouterControls`, `kimiProviderDefaultPreservesReasoningHistory`). Log: `/tmp/mira-tool-thinking.log`.
- Hostless `MiraHostTests`: **104 Swift Testing tests passed**, plus **20 XCTest tests passed and one opt-in real-account test skipped**. Command used `-only-testing:MiraHostTests`; composition/UI targets were not counted as executed.
- Final `Mira` Debug build: **BUILD SUCCEEDED**, using the contributor-prescribed macOS destination, resolved package versions and unsigned build configuration.
- `xcodegen generate` succeeded and produced no project diff. `check_language_policy.py` passed with **2,038 bilingual strings**. `git diff --check` passed.

The complete package acceptance filter is:

```sh
swift test --package-path Packages/MiraKit --filter 'ProductionToolWorkflowTests|TaskToolSequenceTests|AgentToolExecutorIntegrationTests|AgentToolEvidenceTests|AgentToolPolicyCompositionTests|MemoryModuleTests|KnowledgeModuleTests|TaskWorkflowTests|TaskIntegrityTests|ReminderSchedulerTests|MemoryWorkflowTests|KnowledgeWorkflowTests|SessionPrivacyMaintenanceTests|AgentExecutionKernelIntegrationTests|AgentExecutionRecoveryIntegrationTests|AgentBusinessJournalIntegrationTests|SQLiteBusinessEffectsTests|SQLiteBusinessOwnershipTests|MemoryRememberHandlerTests|OpenAIResponsesProtocolTests|HTTPModelAdapterContractTests|HTTPModelFailureTests|AgentHTTPApplicationTests|SessionStateTests|AgentModelExecutorTests'
```

Session-local logs: `/tmp/mira-production-tools-before.log`, `/tmp/mira-task-sequence-before.log`, `/tmp/mira-tool-acceptance.log`, `/tmp/mira-tool-host.log`, `/tmp/mira-tool-build-final.log`, and `/tmp/mira-tool-language.log`. These logs contain synthetic fixtures only and are not repository artifacts.

## Development data and native launch

The current proposal encoding requires `inheritedSources`; no obsolete-format decoder or migration was added. Under the standing contributor authorization, the running development app was stopped, the identified runtime library at `~/Library/Application Support/Mira` was removed, and the same directory was recreated. Keychain was untouched. The final native build was quit/reopened and its accessibility tree confirmed the empty conversation/connect-model state, with no library recovery error. Provider configuration must be set up again in the fresh library.

## Limits

No paid model endpoints or real account tool calls were made. These are real local persistence/execution workflows driven by synthetic model streams, not a measurement of model tool selection or argument quality. Native acceptance here covers fresh-library startup only; there were no UI layout changes. This does not establish macOS 15 runtime behavior, notification delivery, or full native tool workflows.

The memory/knowledge/task management entries remain marked as pending in the native app. In particular, a task proposal that requires manual review is not the same as a committed task, and the unavailable replacement management UI remains a product gap. Empty search results from an empty or local-only library are expected. New saved memories remain local-only until the separate remote-use permission is granted.
