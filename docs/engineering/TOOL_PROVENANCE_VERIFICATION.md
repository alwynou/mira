# Tool provenance correction

Date: 2026-09-18. Branch: `codex/settings-session-analysis`.

## Failure and correction

The normal application recorded authorization denials for memory saving, task listing, memory search and knowledge search before `toolPrepared`. Only tool identities, statuses and structured diagnostics were inspected; no conversation or credential content is included here.

`AgentToolExecutor` merged the model request's inherited sources into `AgentToolPlan.sources`. Domain validators correctly require either no operation sources for a write or sources belonging to their own domain. A prior `sessionExecution` source, or a previous tool's different-domain source, therefore caused valid calls to be denied.

Tool plans now retain their preparation-selected sources. The immutable request remains the owner of inherited/context provenance, bound to the invocation through its attempt. The executor checks that provenance separately through the existing source authorizer before authorization, after approval, after dispatch and before publishing successful read/external results. History, continuation and terminal settlement continue to collect both request and tool sources. Domain validators, business transactions and receipt constraints are unchanged. There is no serialized schema change, migration or development-library reset.

## Verification

- Before the fix, `/tmp/mira-tool-regression-before.log` reproduced denial for all eight registered domain tools after one prior conversation turn, plus failure in a cross-domain continuation.
- `/tmp/mira-tool-regression-final.log`: 69 Swift Testing tests in 8 focused suites passed. The eight-tool parameterized regression covers `memory.remember`, `memory.search`, `memory.get`, `task.change`, `task.list`, `knowledge.search`, `source.open` and `source.read_chunk`. The continuation test runs task, memory and knowledge reads in consecutive model steps and verifies that inherited task provenance remains on requests and recorded evidence.
- The focused suites also cover exact user evidence, forged input, domain permissions, cancellation/draining, recovery, receipts, history, and revoking an inherited source while awaiting approval. The latter denies dispatch and commits no business operation.
- `/tmp/mira-tool-host-tests-final.log`: `MiraCompositionTests/LibraryExecutionTests` passed both parameter cases (fresh conversation and one earlier turn). It uses the real macOS composition and domain validators, verifies the task receipt and thinking/result projection, then reopens the library without repeating the effect. An earlier run exposed only a new test's incorrect assumption about message-page ordering; the assertion now selects the execution explicitly.
- `/tmp/mira-tool-fix-build.log`: macOS Debug app build succeeded. The previous normal app was closed gracefully and the rebuilt app was launched against the existing development library. No runtime data or configuration was deleted.
- `xcodegen generate`, `git diff --check` and changed-document relative-link checks passed.

All new model replies and libraries are synthetic. No paid endpoint was called. A live-provider retest and macOS 15 runtime verification remain outside this evidence.
