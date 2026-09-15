# Local Release packaging

This procedure creates an unsigned local Release ZIP from one resolved Git
revision. It is a reproducible build check for a development machine; it is
not evidence of signing, notarization, native UI acceptance, provider
compatibility, or installation on every supported Mac.

Run it from the repository root:

```sh
python3 scripts/package_local.py \
  --revision HEAD \
  --output-directory /private/tmp/mira-local-package-candidate
```

`--revision` is required and must resolve to a Git commit. The helper archives
that commit into an isolated temporary source tree, so untracked files and
worktree edits are excluded. `--output-directory` must be an absolute path
that does not exist; its existing parent is never modified except for the new
output directory. Existing files are never overwritten.

The helper uses the committed Xcode project and package lockfiles, builds the
Mira scheme in Release with `CODE_SIGNING_ALLOWED=NO` and
`CODE_SIGNING_REQUIRED=NO`, and requests both `arm64` and `x86_64` slices.
Xcode may fetch the exact pinned package sources when they are absent from
its cache; automatic dependency version resolution is disabled. The helper
does not launch Mira, access provider credentials, or make model requests.

Successful output contains:

- `Mira-<version>-<commit>-unsigned.zip`, the app bundle ZIP;
- the matching `.sha256` file;
- `manifest.json`, including the exact revision, ZIP SHA-256, bundle digest,
  architecture, version, minimum macOS, signing classification, resources,
  and toolchain details;
- `toolchain.json` and `revision.txt`; and
- `xcodebuild.log`.

The helper checks the app bundle's `Info.plist`, minimum macOS 15 declaration,
`arm64` and `x86_64` executable slices, `ThirdPartyLicenses.txt`, English and
Simplified Chinese localization resources, and `codesign -dv` output. With
the requested settings, the required local result is unsigned or ad hoc
linker-signed. It extracts the ZIP and compares file bytes, paths, modes, and
symlink targets with the built bundle. This reproduces the delivered bundle;
it does not promise identical ZIP bytes across separate compiler runs.

After a successful build, process and persistence checks are separate:

1. Launch `Contents/MacOS/Mira` directly with a fresh UUID-based
   `--data-directory` and wait for `Mira.sqlite` to appear.
2. Inspect the database schema version, terminate the process, and launch it
   again against the same directory.
3. Repeat with a second directory and confirm that both libraries remain
   independent. Use the package's synthetic SQLite persistence and backup
   tests to prove stored conversations and restored records.

Use a Debug build with the explicit `--demo` flag for the fake-provider
streaming walkthrough. Release builds deliberately do not enable that path.
The normal library is `~/Library/Application Support/Mira`; an explicit data
directory is the supported way to inspect a restored or disposable library.

For local installation, extract the ZIP into a directory you own and keep the
whole `Mira.app` bundle together. The development artifact has no Developer ID
signature or notarization ticket and is not a public download release. The
current evidence applies only to the tested host; an Intel executable slice
does not establish Intel runtime acceptance.

Quit the running app before replacing its bundle. Back up the library first
and retain the previous bundle until the new build opens the intended
library. Current development builds accept only their current schema; they
reject older formats without converting or resetting them. Use a separate
`--data-directory` for incompatible development builds.

Removing the app bundle leaves its library and Keychain items in place. To
remove a configured credential, remove its connection in Settings and allow
credential cleanup to complete. Deleting a library directory is a separate,
explicit data-removal operation; neither packaging nor local installation
performs it. Existing backup bundles also remain separate copies.

If the build fails, the output directory remains in place with
`xcodebuild.log`, `toolchain.json`, `revision.txt` when available, and
`error.txt`. The temporary extracted source and DerivedData are removed after
the attempt. A failed build must be investigated from its preserved log
before any output directory is reused; choose a new directory for the next
run.

The canonical editable app icon is the Icon Composer package at
`Apps/MiraMac/Resources/MiraAppIcon.icon`. Keep its layer assets inside that
package rather than maintaining duplicate exported copies elsewhere in the
repository. If the icon changes, commit the package, `project.yml`, and the
regenerated Xcode project before running this procedure; a worktree-only icon
must not be counted as part of the ZIP.
