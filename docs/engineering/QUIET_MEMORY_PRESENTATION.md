# Quiet memory presentation

Date: 2026-09-24. Issue: [#63](https://github.com/alwynou/mira/issues/63).
Host: macOS 27.0 (26A428), Xcode 27.0 (27A266a), Apple Silicon.

Ordinary replies now use memory silently. Shared conversation instructions, recall
guidance and memory tools prohibit visible memory references, IDs and revision
metadata. Successful saves receive a brief natural acknowledgment; commit,
local-only, failure and replacement-history distinctions remain explicit.

The host removes reserved memory annotations from assistant presentation and
known bare IDs from the same turn's memory-tool receipts. Flat and ordered
Markdown rendering, streaming and reopened history share that boundary. The
ordinary footer no longer includes memory citations or lifecycle tags. Knowledge
citations and explicit deletion outcomes remain. Journals, user messages,
thinking, tool evidence, source authorization and deliberate inspection remain
unchanged. This does not remove arbitrary UUIDs from answers.

## Focused checks

- Package: 23 tests passed across `MemoryRememberToolTests`,
  `MemoryAcknowledgmentWorkflowTests` and `MemoryModuleTests`. Coverage includes
  committed, pending, failed and refused save wording, local-only receipts,
  replacement history, schema bounds and recall instructions.
- Host: 41 tests passed across `NativeTranscriptStateTests`,
  `NativeTranscriptRowTests`, `MemoryContinuityEvidenceTests` and
  `MemoryContinuityHandoffTests`. Coverage includes flat/ordered native rendering,
  absent memory footers, streamed and interrupted reference prefixes, bare
  receipt IDs, preserved raw text, unrelated UUIDs and Knowledge references.
- The continuity evaluator now rejects visible references and known IDs, even
  for the unchanged authored source-request scenario. Its current corpus and
  handoff field is `asksForSource`; source identity and receipt checks remain.
  All 15 launcher tests passed.
- The resolved-package Debug app build, language policy (2,343 bilingual strings)
  and whitespace check passed. Project generation includes the presentation
  helper in the explicit host/composition target source lists. No design tokens
  changed.

The first local host compilation exposed the missing explicit target source
entries. A streaming regression also caught a dangling opening bracket when a
complete reference lacked its closing delimiter. Both were fixed before the
passing runs. Native renderer assertions normalize its empty text views and
trailing newline; they still inspect the actual rendered text and hidden footer.

## Native evidence

A separate ad-hoc signed demo app used a disposable synthetic library, with no
network or Keychain access. Its local driver echoed a synthetic memory annotation
into a real assistant turn. The assistant text and footer hid it; the user fixture
and canonical journal retained it. Reopening the same conversation in Chinese
dark appearance preserved the result.

- [English/light, 1100 × 800 launch size](evidence/quiet-memory/en-light.png)
  and [normalized accessibility evidence](evidence/quiet-memory/en-light.json).
- [Chinese/dark, 850 × 620 minimum launch size, reopened history](evidence/quiet-memory/zh-dark-reopened.png)
  and [normalized accessibility evidence](evidence/quiet-memory/zh-dark-reopened.json).

Fixture prose intentionally stays English in both UI locales. The visible marker
in the user bubble is authored test input, not an assistant citation. The native
screens show the natural reply without a memory badge, usable composer and
preserved titlebar. Earlier capture attempts returned Stage Manager thumbnails;
the retained captures show the complete window. The final backtick-wrapper
extension is covered by the subsequent host test and app build; the screenshots
exercise square-bracket references.

Unverified: live-provider compliance with the new prose instructions, VoiceOver,
Reduce Transparency, Increase Contrast, fullscreen/multiple displays and older
macOS runtime. No paid provider evaluation was run. These focused checks do not
close broad memory-quality acceptance.
