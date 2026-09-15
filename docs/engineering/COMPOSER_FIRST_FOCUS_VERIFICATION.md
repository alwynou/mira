# Composer first-focus flash

Date: 2026-09-14. Host: macOS 26.6.2. Scope: first and subsequent composer focus, transient window creation, and basic text insertion.

## Cause

A fresh offline Mira process reproduced a separate window on first composer focus. WindowServer sampling at approximately 8 ms observed a Mira-owned level-101 window, 312 × 237 points, appear at 3.358 seconds and disappear at 3.368 seconds. Focus moved to the sidebar at 6 seconds and back to the composer at 8 seconds without another window appearing.

A temporary Debug-only window-order trace identified `SPRoundedWindow` with `NSRemoteView` content. Its stack included:

```text
SafariPlatformSupport: displayOTPAutoFillRelativeToRect:ofView:oneTimeCodeMode:completionHandler:
SafariPlatformSupport: _setUpCompletionListViewControllerWithSetUpCompletionListViewController:
ViewBridge: viewDidAdvanceToRunPhase:
SafariPlatformSupport: completionListPreferredContentSizeDidUpdate
SafariPlatformSupport: _dismissCompletionListWindowIfNecessary
```

This establishes the system one-time-code AutoFill presentation path rather than the composer material or model menu. The first-use remote-view setup produces the short-lived panel; subsequent focus did not reproduce the panel in the same process. No Mail, Messages, credential, or proposed AutoFill content was inspected.

Apple documents that macOS 26 enables Security Code AutoFill in ordinary text inputs unless the app opts into explicit content-type requirements. See [NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac](https://developer.apple.com/documentation/bundleresources/information-property-list/nsautofillrequirestextcontenttypeforonetimecodeonmac).

## Fix

Set `NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac` to `true` in `project.yml` and regenerate the app Info.plist with XcodeGen. AutoFill remains available to a future field explicitly annotated as `oneTimeCode`; the conversation composer is a general text input and has no such annotation. No global system preference, input-method setting, text-correction behavior, or layout changed.

The temporary window method instrumentation was removed after diagnosis. The final production change is only the app configuration key and generated plist.

## Verification

- Debug app build passed; the built bundle contains the Boolean key set to `true`.
- With the key enabled, repeating the same fresh-process focus sequence produced no elevated Mira window and no AutoFill window-order trace.
- The final build without instrumentation was checked again with a fresh temporary demo library: first focus, synthetic text insertion, focus away, and second focus. Results are recorded in [focused evidence](evidence/2026-09-14-composer-first-focus.json).
- All temporary demo processes were stopped and their libraries removed. No provider calls or unrelated test suites were run.

This addresses the reproduced first-focus panel on the current macOS host. It does not claim a full IME composition, accessibility, or older-macOS runtime matrix; no input implementation was replaced.
