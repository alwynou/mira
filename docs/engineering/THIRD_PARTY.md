# Third-party notices

MiraMac uses the pinned `MarkdownView` package at revision
`757b6fcc4b3095e84f4c0613f4b98147f49dcd09`, the pinned `ListViewKit` package at
revision `c6a067ba837758a50612f88dd1d6bb025175df6c`, and the pinned `Litext`
package at revision `130b4eef642d76a3d2dcf07ab966f32f08e14b90`. The package
URLs and revisions are declared in `project.yml`; the resolved graph is kept in
the committed Xcode `Package.resolved` file. `MiraKit` does not import these UI
dependencies.

The shipping renderer graph is:

- MarkdownView products `MarkdownView` and `MarkdownParser` — MIT.
- ListViewKit — MIT; its `MSDisplayLink` dependency is MIT.
- Litext — MIT.
- Highlightr — MIT; its bundled `highlight.js` asset is BSD 3-Clause.
- SwiftMath — MIT; its bundled math fonts include the MathChat MIT notice,
  GUST Font License notice, and STIX / SIL Open Font License 1.1 notice.
- LRUCache — MIT.
- swift-cmark — BSD-style notices for cmark-gfm and its derived components.
- swift-collections — Apache License 2.0 with the Runtime Library Exception.
- GRDB.swift — MIT.

The complete notices and license texts used by the app are in
`Apps/MiraMac/Resources/ThirdPartyLicenses.txt`. The resource also retains the
models.dev catalog-data MIT notice. Upstream package tests, examples, source
fixtures, and obsolete renderer vendor sources are not part of the
Mira build or shipping resource.

When the renderer graph changes, inspect each resolved checkout's license,
NOTICE, bundled-resource, and font-attribution files, then update the resource
and this inventory together. Do not infer transitive attribution from a package
name alone.
