# Provider key activation

Date: 2026-09-20. Issue: [#5](https://github.com/alwynou/mira/issues/5).

## Problem

After a user entered a key for an unconfigured catalog provider and enabled or saved it, the Settings destination could remain `.catalogProvider(id)` while the catalog entry was no longer considered unconfigured. The view then fell through to the first active connection (or another catalog entry). During the same refresh, `onChange(of: model.revision)` updated the connection editor for that fallback destination, so the save callback's captured-editor guard could no longer navigate to the newly created connection. The page could display the wrong model list until reopened.

The parent reproduced the reported failure in the native app before this fix: after entering a synthetic DeepSeek key and enabling the provider, Fetch Models and Add Manually became available but both visible model switches remained disabled. Their accessibility nodes retained the catalog state. The identity change and destination resolution together passed the same first-activation workflow after the fix.

## Change

- `ProviderLibraryModel.configuredConnection(forCatalogProviderID:)` resolves a catalog destination to its saved connection.
- `ProviderConfigurationView` resolves that connection before applying the first-active-provider fallback and recreates the provider content owner when the resolved destination changes.
- After refresh, the save callback navigates when either its editor is still selected or the resolved destination is the saved connection. This preserves Custom Provider navigation and avoids overriding a different selection.

This preserves the product contract: saving and activation are local operations, provider activation does not enable model descriptors, and a failed credential or settings save does not publish provider or model state.

## Synthetic regression coverage

`ProviderLibraryModelTests.catalogProviderActivationResolvesToNewConnectionAlongsideAnotherActiveProvider` creates a second provider while another provider is active, then verifies the catalog destination resolves to the newly created connection before enabling its model. It covers Save followed by activation and subsequent model disable/re-enable without reopening. `ProviderLibraryModelTests.typedKeyCanActivateCatalogProviderBeforeExplicitSave` covers the switch path directly after typing a synthetic key. `ProviderLibraryModelTests.activationSaveFailureDoesNotPublishProviderOrModelState` injects a Keychain save failure and verifies no callback, connection, or model state is published.

## Verification

- Debug app build with pinned dependencies and signing disabled passed (`/tmp/mira-provider-key-build.log`). Language policy and diff checks passed.

- The focused `MiraCompositionTests/ProviderLibraryModelTests` and `ProviderConnectionSettingsModelTests` run passed: 17 tests in 2 suites. It includes the three new regressions. Final log: `/tmp/mira-provider-key-tests-final.log`; result: `.build/xcode/Logs/Test/Test-Mira-2026.09.20_11-10-19-+0800.xcresult`.
- English/light native workflow: with an existing active DeepSeek connection, configure Anthropic, save, enable, and immediately include a model in the pool. The page stays on Anthropic throughout; no reopening or provider reselection is required.
- Chinese/dark native workflow: in a new isolated library, attempting activation with no key shows the localized validation message and keeps activation off. Entering a synthetic key and activating immediately enables the model switches; a model was then successfully included in the pool on the same page.
- Native screenshots were inspected in both appearances and at the 760 × 612 pt Settings window minimum (560 pt content plus native toolbar). Scrolling keeps the enabled model controls accessible at this size.
- Native checks used only synthetic keys and isolated libraries. No Test, Fetch Models, or model execution was invoked. The three synthetic Keychain entries and isolated libraries were removed after stopping the app. The normal library and its credentials were untouched.

Reproduction command for the focused tests:

```sh
xcodebuild -project Mira.xcodeproj -scheme Mira -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/xcode \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGN_IDENTITY=- \
  -only-testing:MiraCompositionTests/ProviderLibraryModelTests \
  -only-testing:MiraCompositionTests/ProviderConnectionSettingsModelTests test
```

Native Keychain fault injection, actual remote credentials/endpoints, and macOS 15 runtime were not exercised. Synthetic failure coverage verifies that failed credential persistence publishes neither a connection nor model activation. This increment changes no schema or provider-request behavior.
