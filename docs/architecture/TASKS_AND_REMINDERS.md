# Tasks and local reminders implementation

This document owns the implemented M6 contract. Product meaning remains in
[Records](../product/RECORDS.md); acceptance evidence belongs in engineering.

## Canonical records and source authority

`MiraTask` is a scoped task with title, notes, optional due time, status, revision,
and an optional one-time reminder. The first increment supports one reminder per
task; a reminder command creates its associated task. Inbox tasks and each
workspace have separate lists. Completion and cancellation retain history.
Reopening is an explicit user action. Editing a past reminder requires choosing a
new future time before it can be armed again.

Task changes commit the current row, a `TaskRevision`, and an idempotent operation
receipt in one SQLite transaction. Updates require the current revision. A
completed tool invocation can replay its existing receipt after source, argument,
scope, and privacy revalidation; it cannot perform another mutation. Identical
tool proposals from the same source message share a business key so a model's
repeated calls do not create duplicate tasks. Separate user messages remain
separate requests.

Manual UI changes are explicit user operations. `task.change` can directly commit
only a recognized command with its exact whole current-message quote and a
source-grounded title/notes. Existing targets require a current ID and revision
from `task.list`, the same workspace, and a title present in the source. Unclear
intent or a pronoun-based target produces a separate `TaskProposal` for review.
Model arguments never grant authority. The store checks the durable invocation,
source, workspace policy and frozen provider identity inside the write
transaction. Tools disclose task content only within the execution's current
workspace and its outbound policy.

Proposals preserve their original source and absolute interpretation across app
restarts. Review can edit, accept or reject them. An unknown reminder time cannot
be accepted until an exact future time is chosen. Accepting a stale target
revision fails instead of applying the change to a newer task. Proposal acceptance
is a compare-and-set transition; a repeated decision returns a conflict. A
proposal receipt is never reported as a committed task or a scheduled notification.

## Time interpretation

Enqueue atomically saves the current IANA time-zone ID in `message_time_context`
with the user message and execution. Retries reuse that message and its original
timestamp. `task.list` returns this reference clock; `task.change` accepts a local
`HH:mm` plus either an explicit `YYYY-MM-DD` or a relative day offset.

`TaskTimeResolver` uses the source date and zone, strict Gregorian matching, and
both first/last repeated-time policies. Invalid dates, DST gaps and DST overlaps
require review; the host never silently chooses an occurrence. Direct commits also
check the exact source time expression against the proposed day and clock. The
reviewed English/Chinese grammar covers common today/tomorrow commands, numeric
times and whole afternoon/morning hours. Other date wording can be reviewed as a
concrete proposal. Recurring and conditional reminders return unsupported rather
than being silently converted to one-time notifications.

Due dates and reminders are distinct: setting a task's due date alone does not
enable a notification. Original source time zones are shown with dates. UI date
pickers operate in the record's time zone.

## System delivery

`LocalNotificationPort` is defined in Foundation-only Core. The macOS adapter uses
`UNUserNotificationCenter`; the application-owned `ReminderScheduler` serializes
reconciliation. System permission is requested only by an explicit UI button.
Demo and tests use injected notification adapters and do not change system
permissions or queue real notifications.

Each request identifier contains a library-path namespace and stable task ID.
The trigger uses the already resolved absolute instant in UTC. A successful add
is checked against pending system requests before the current task revision is
marked scheduled. Revisions are checked after every external operation; a stale
result is removed and the current desired state is reconciled again. Genuine
scheduling failures remove the previous request and remain retryable. Cancellation
does not become a fabricated system failure.

The canonical record and observed delivery have separate states:

- `pending`: saved, system scheduling not yet confirmed;
- `scheduled`: the system accepted this task revision;
- `permissionRequired`: saved, notification permission is unavailable;
- `failed`: scheduling failed and may be retried;
- `elapsed`: the trigger time passed; this is not proof that the user saw an alert;
- `paused`: restored from backup and waiting for explicit resumption;
- `cancelled` / `none`: no reminder should remain armed.

Completion, cancellation and disabling a reminder remove pending and delivered
notifications for its identifier. Startup and application activation reconcile
current desired state and permission changes. Orphan pending requests are removed only after an exact library-prefix match and an independent task-existence lookup; absence from a bounded work page never implies deletion. At most 60 future active reminders
are admitted, keeping this initial schedule bounded. There is no background
helper, recurrence engine, EventKit publishing, Calendar integration or sync.

The adapter follows Apple's [local notification scheduling documentation](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app).
System delivery after app exit, Focus behavior and permission prompts require
attended native acceptance; a successful mocked port does not establish those.

## Storage and recovery

Current schema 12 adds `mira_tasks`, `task_revisions`, `task_proposals`,
`task_operations` and `message_time_context`. There are no old-schema converters.
Backup validation checks canonical task JSON, indexed values, revision/evidence
bindings, proposals, operation receipts and time-zone metadata. Restoring a backup
pauses future reminders; opening the restored library never automatically arms
them. A user can resume each reminder after inspecting its time.

`TaskIntentPatterns.json` contains reviewed English/Chinese matching expressions. The non-English entries are intentional user-language recognition data, not translated built-in prompts or display strings. All tool descriptions remain English and the UI uses the string catalog.
