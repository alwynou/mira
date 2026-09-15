# Deferred management interfaces

As of 2026-09-08, the Memory, Knowledge, and Tasks management screens are removed. Their sidebar entries remain visible as no-op, localized “Not implemented yet” entries; the Knowledge toolbar entry follows the same rule. Removed destinations have no mounted view or sheet, and memory extraction feedback no longer links to a removed management screen.

MiraCore domain models and use cases, runtime execution, storage, memory and knowledge tools, notification delivery, and conversation memory editing, approval feedback, and citations remain in place where currently supported. The three orphaned management presentation models and their screen-specific tests were removed alongside the obsolete task UI suite. Unreferenced translations from these screens and abandoned navigation were removed; the existing navigation test covers deferred entries.

The post-cleanup `testDeferredNavigationPreservesConversationDraft` passed with an isolated offline demo library (96.808 seconds, including application-window interruptions): all three sidebar entries and the Knowledge toolbar entry preserved the exact unsent draft, one conversation, and the absence of a sheet or extra window. Debug app and host tests, project generation, language policy validation (1,127 bilingual strings), and `git diff --check` passed. Logs are under `.build/ui-commit/`; the later settings UI test did not complete and is not included in this result.

This verification covers navigation removal and draft preservation only. Replacement management interfaces, appearance and language-layout matrices, sidebar-animation performance, paid model requests, and live-memory evaluation remain outside scope.
