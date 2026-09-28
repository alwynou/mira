# Bash and global tool permissions

## Host policy

`ToolPermissionPreferences` is a MainActor Observable owner persisted in UserDefaults under `tools.permissionLevel`. Both UI entry points observe this one instance. The production library injects an asynchronous level reader into each work group, including groups recreated after maintenance. Tests inject isolated values; explicit Debug demo mode uses a separate preference domain. No library schema or journal format changes.

`MacToolPolicy` retains the host's enabled-effect gate and delegates its approval decision to `MacToolPermissionPolicy`. The latter classifies every tool, including reads and local writes. Known internal memory/knowledge/task reads and the exact local-write name/namespace pairs for memory save, memory retraction and task changes are routine. Memory deletion and every unclassified capability are guarded. An external tool cannot inherit a routine classification by using a familiar local-write name. Registered domain validators still check exact descriptors, prepared input, source/target revisions and admitted user evidence.

Ask requires review for all nonroutine actions. Automatic additionally permits recognized read-only Bash commands. Full access permits enabled tools at the host approval layer, while module policies, source authorization, current library epoch, cancellation and OS permissions remain enforced. A setting is sampled at policy evaluation. Changes govern later evaluations, not already approved/running calls, and do not answer pending approvals. Stop cancels an active execution. Tool results and model output cannot change the preference.

Reviews bind the existing invocation, proposal hash, execution, library authorization and five-minute expiry. Bash review shows the prepared command, resolved directory and timeout. Generic review contains exact tool identity, prepared JSON input and target references. Reviews above 4096 UTF-8 bytes fail closed without truncation. Denial, expiry, absent observers or cancellation cannot dispatch an action requiring review. Automatic permissions do not require a UI observer. There is no additional persistent blanket approval token.

## Conservative Bash classification

Preparation pins recognized literal `pwd`, `ls`, `cat`, `head`, `tail` and `wc` to their `/bin` or `/usr/bin` executables. It freezes the resulting command in the durable plan, so review and dispatch see the same value and PATH shadowing cannot substitute another executable. All other commands retain their original text.

The recognizer accepts literal space-separated words with balanced single/double quotes and a small explicit option set. It excludes expansions, escapes, shell operators, redirects, newlines/control characters, globs, comments, assignments and unknown options. `head`/`tail` accept literal operands only; follow mode, custom counts and other options require review. Option-looking operands require review. The canonical form quotes every argument, and policy only recognizes that exact canonical form. Unsupported syntax is uncertain, not automatically harmful, and still works after review or in Full access. This is an approval convenience, not a shell parser or a security sandbox. A recognized read may still expose file contents to the selected model.

## Process adapter

`MacBashTool` is an exclusive external-write capability in MiraMac. MiraCore remains Foundation-only. Its constrained module policy validates the canonical plan and descriptor but leaves permission-level approval to the global host policy.

Input limits are 2048 UTF-8 bytes for command text and 1024 for an absolute working directory. The directory is standardized, resolved and checked during preparation and again before execution. Timeout defaults to 30 seconds and is bounded to 1–90 seconds; the executor budget is 120 seconds. Each call spawns `/bin/bash --noprofile --norc -c`, with stdin at EOF and only an explicit PATH, HOME, TMPDIR, LANG, LC_CTYPE and TERM environment. It inherits no application environment, shell startup file or exported function. The working directory is not confinement and the account's existing network and file access remain available.

Separate nonblocking pipes continuously drain stdout and stderr, each retaining at most 4096 raw bytes. Results include decoded text, truncation flags, exit code, termination signal and timeout status. Nonzero command exit is a collected result; callers must inspect it. Output remains untrusted. Invalid UTF-8 is replaced so results remain encodable within the 65536-byte tool-result bound.

The adapter creates a process group. Cancellation, timeout or leader exit starts bounded TERM/KILL cleanup, including background children that retain pipe writers, then reaps the leader. `waitid` observes exit without reaping before the last group signal, reserving the leader PID. An unexpected wait failure prevents further group signals. Cooperative app/library shutdown drains these executions. This is not a daemon supervisor: a descendant that deliberately escapes the group, or abrupt host process death, can leave external work running. No PTY, interactive input, persistent shell, privileged helper or background-job API is provided.

## Durable effects and scope

All Bash calls remain external writes even when recognized as read-only. Existing journals persist prepared intent, approval when required, dispatch and settlement. After dispatch, cancellation or missing settlement preserves an unknown external effect; recovery never automatically executes the command again. Timeouts and cancellations cannot undo filesystem or network effects already performed. Shell text/output belongs only to the existing protected conversation evidence, never ordinary diagnostic logs. Built-in instructions prohibit credential access and direct edits to Mira's library; this is guidance, not filesystem isolation.

This is the user's explicit expansion of the previous deferred-shell scope. General plugin loading, arbitrary executable safety inference and per-directory access grants are not implemented. Verification and remaining gaps are recorded in [engineering evidence](../engineering/TOOL_PERMISSIONS_VERIFICATION.md).
