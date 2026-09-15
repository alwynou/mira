# Mira vendored ListViewKit

This directory vendors [ListViewKit](https://github.com/Lakr233/ListViewKit) at revision
`c6a067ba837758a50612f88dd1d6bb025175df6c`.

The upstream license is included in [`LICENSE`](LICENSE). Mira keeps the
package source local so the production transcript can use the native AppKit
scrolling backend without editing Swift Package Manager's resolved checkout.

## Mira changes

- `Sources/ListScrollView.swift` uses `NSScrollView` and its native
  `NSClipView` as the scroll owner. It exposes the virtual document geometry,
  applies height compensation after installing the new document size, and
  preserves the ListViewKit scrolling aliases and cancellation API.
- User interaction comes from AppKit live-scroll notifications and scroll
  event phases. `onUserScroll` fires at native live-scroll start and on wheel
  input, allowing presentation navigation to yield immediately. No wheel event
  monitor, private hierarchy inspection, or interaction timeout is used.
- `Sources/ListView.swift` and `Sources/ListView+SliceDrain.swift` write the
  virtual document through `listContentSize`, use `rowContainer` for mounted
  rows, and measure against `viewportSize`.
- `Sources/ListRowLayout.swift` measures row widths against the effective
  viewport width, excluding clip-view content insets.
- `bottomContentPadding` adds blank space to the native document after the virtual
  content. It changes scroll range without registering a native bottom inset or
  shrinking the viewport; row positioning accounts for the covered area.
- Explicit programmatic navigation uses a cancellable, Reduce Motion-aware
  animation. Native wheel elasticity and scrollbar input remain AppKit-owned.
- Document shrinkage clamps idle offsets to the new native bounds; unchanged
  layout preserves live elasticity. Height compensation retains virtual anchors.

The package remains platform code and does not depend on Mira or runtime data.

The package manifest targets macOS 15. Upstream example apps, benchmarks, CI and
Git checkout metadata are not part of this source vendor.
Tests for the removed custom AppKit physics, scroller, ambient animation
geometry, and interaction timing are omitted from this source vendor;
the anchor tests that cover virtual measurement compensation remain enabled;
virtual layout, diffing, row reuse, and platform-independent animator tests remain
enabled. `NativeScrollBackendTests` covers inset geometry, compensation, bounded
row mounting, live-scroll state, and cancellation of programmatic animation.
