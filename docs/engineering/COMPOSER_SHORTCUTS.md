# Conversation composer Return shortcuts

Date: 2026-09-20. Issue: [#6](https://github.com/alwynou/mira/issues/6).

The composer now handles Return while its native text editor is focused. Return calls the same guarded send action as the Send button. Command-Return asks the native editor to insert a newline, preserving its selection and text-editing behavior. Marked input is left to the input method. Empty drafts, model selection, unavailable models, active execution and pending persistence cannot trigger a new submission.

The centered sending/shortcut hint and its custom three-column layout are removed. Execution status stays leading; the model selector and Send/Stop controls stay trailing. The component preview and generated token export no longer contain the unused footnote style. Product behavior is defined in [Workspace and conversation](../product/WORKSPACE_AND_CONVERSATION.md) and [Design system](../product/DESIGN_SYSTEM.md).

## Verification

- Debug app build with pinned packages and signing disabled: passed (`/tmp/mira-composer-shortcuts-build.log`).
- `python3 scripts/check_language_policy.py`: passed, 2,162 bilingual strings.
- Native regression tests exercise empty and whitespace-only drafts, newline insertion at the caret and over a selection, Return submission, and retained drafts during an active execution in English/light and Chinese/dark. Final execution results are pending.
- The initial unsigned UI runner was killed before tests started; subsequent native runs use local ad hoc signing. An initial signed run encountered XCTest's input-source switching failure before entering fixture text; fixtures now use the project's existing paste-based input technique.

## Remaining checks

Actual Chinese IME candidate confirmation and macOS 15 runtime behavior require separate verification. English/Chinese UI localization checks do not establish IME behavior. No real model endpoint is needed for these synthetic tests.
