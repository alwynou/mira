# Contour Silver app icon

Date: 2026-09-07. Status: the user selected **01 Silver** after reviewing shape, color, and size studies. The selected icon is integrated in the app and the Debug build passes.

## Source and deliverables

The canonical editable source is [MiraAppIcon.icon](../../Apps/MiraMac/Resources/MiraAppIcon.icon). Its two SVG assets use a shared 1024 × 1024 canvas. The continuous foreground ribbon and returning loop are listed front-to-back in Icon Composer. The former separate underside is merged into the foreground path, removing the internal seam and its duplicated material edge. The inner shoulder and lower tip use smooth curves; one gradient spans the entire foreground surface. Each uses an opaque grayscale linear gradient to retain the selected silver-to-graphite tonal pattern. Source layers contain no raster images, fonts, shadows, glows, strokes, or enclosing mask.

The [product identity contract](../product/VISUAL_IDENTITY.md) defines the selected shape and palette. The approved larger silhouette and silver-to-graphite palette are retained from the Silver study, with rounded transitions and a continuous foreground gradient. Icon Composer supplies material edges, inter-layer shadows, translucency, and the system enclosure. Material settings are intentionally restrained: neutral shadow opacity 0.22 and group translucency 0.05.

Deliverables are in [the final review folder](../../designs/mira-app-icon/final/preview.html):

- `Mira-Silver.svg`: a standalone vector presentation, with an approximate enclosure and presentation-only shadow. It is not a production import layer.
- `mira-logo-black.svg` and `mira-logo-white.svg`: transparent website logos, respectively graphite for light backgrounds and silver for dark backgrounds. They retain the canonical geometry and add standalone gradient/edge/shadow treatments; they are not Icon Composer input layers.
- `Default-1024.png`: a 1024 px Apple-rendered image.
- Default, Dark, ClearLight, ClearDark, TintedLight, and TintedDark at 512 px.
- Default exports at 16, 24, 32, 64, and 128 px.
- Two additional light-angle exports at −45 and +45 degrees.

Run `python3 scripts/render_app_icon.py` to reproduce the standalone SVGs and all 14 native previews from the app source. The script uses the installed `ictool`, checks its stderr as well as exit status, and never writes the canonical `.icon` document. CoreSVG parse errors can otherwise yield an apparently successful export with missing artwork.

Only the selected design and its final exports remain in `designs/mira-app-icon/`. Unused concepts, intermediate studies, and their generators were removed. The canonical app source remains `MiraAppIcon` at the existing resource package path.

## Apple guidance reviewed

Primary sources retrieved on 2026-09-07:

- [App icons — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/app-icons), June 8, 2026 revision; the official DocC JSON was read because the HTML page requires JavaScript.
- [Icon Composer](https://developer.apple.com/icon-composer/), including current refraction, specular, and rendering-mode guidance.
- [Create icons with Icon Composer — WWDC25](https://developer.apple.com/videos/play/wwdc2025/361/), covering artwork preparation, layers, and Xcode delivery.
- [Say hello to the new look of app icons — WWDC25](https://developer.apple.com/videos/play/wwdc2025/220/), covering grid, materials, and simplification.
- [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).

Applied constraints: square vector layers, centered artwork, a minimal layer count, clear edges, no source enclosure, consistent geometry across appearances, and system-controlled material effects. The user-selected tonal gradients are intentional artwork, tested with the native renderer; draft-generated highlight strokes and shadows were removed from the production layers to avoid doubling the system's effects.

## Verification

Host: macOS 26.6.2 (25G83), Xcode 26.6 (17F113), Icon Composer/ictool 1.6 (99.1).

- Both production SVGs parse as XML, have the expected 1024 px viewBox, use only grayscale stops, and contain only vector geometry/gradients and English titles.
- The Apple renderer exported all 14 images successfully without stderr output. Default and Dark retain the approved black-and-silver design; clear and tinted renditions retain its geometry. System tint is user-controlled and can produce a much darker appearance than Default.
- Visual inspection covered the native Default/Dark treatment, clear and tinted exports, alternate lighting, and the small-size strip. The comparison page presents fixed image exports; its clear images are not a simulation of live wallpaper refraction.
- `xcodegen generate` completed with no project or `project.yml` diff.
- The required Debug app build succeeded using the pinned package versions and `CODE_SIGNING_ALLOWED=NO`. Log: `.build/icon-build.log`. The latest resource update build completed without warnings.
- The built bundle declares `CFBundleIconName = MiraAppIcon` and contains the generated `MiraAppIcon.icns` and `Assets.car`. The bundled ICNS was decoded and visually inspected; its system-provided exterior padding and silver ribbon are present.
- `git diff --check` passed. No Swift behavior or localization changed, so package and hostless language tests were not required for this resource-only change.

This is local rendering and build evidence, not a macOS 15 runtime test. An installed-app Dock/Finder cache refresh and macOS 15 runtime appearance have not been tested. The task does not change the installed app or its library.
