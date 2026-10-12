# EluviumExample

> iOS and Mac Catalyst app demonstrating [Eluvium](../..) end to end: the bundled starter pack, the resolve pipeline, feed and list browsing with audio playback, catalog enumeration, archive imports, and entity identity.

## Getting Started

```bash
brew bundle
```

Open in Xcode:

```bash
open EluviumExample.xcodeproj
```

## Build & Test

```bash
make build
make test
make check  # SwiftLint + SwiftFormat
```

Mac Catalyst:

```bash
xcodebuild build -project EluviumExample.xcodeproj -scheme EluviumExample \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
```

## Tech Stack

- **Platform**: iOS 18.0+, Mac Catalyst (Optimize for Mac)
- **UI Framework**: UIKit (programmatic)
- **Design System**: LumiKit 1.x
- **Layout**: SnapKit
- **Ingestion**: Eluvium (EluviumCore / EluviumCatalog / EluviumNet / EluviumDOM / EluviumPlaces / EluviumUI)

## The Five Tabs

| Tab | Demonstrates |
|-----|--------------|
| **Paste** | Paste any URL and run recognize → fetch → extract → assemble, with typed failure copy and the resulting record card; feeds, podcasts, and albums chain into an item browser with audio playback. "Try an example…" opens the pack's example corpus as a tap-to-run browser. |
| **Sources** | The installed starter pack: every active source's match rule, fetch plan, and example count, plus the sources this binary skipped and why. |
| **Catalogs** | A resumable catalog walk (PokéAPI dex) with visible cursor state and run / run-to-end / stop / restart controls, deduped on externalId, plus the pack's seeded lists resolving into browsable list records. |
| **Imports** | Archive import from the document picker or a file dropped on the screen, with row-level results. Bundled samples (a Flighty CSV, an OPML subscription list, a sharded Twitter archive export, and a 微信读书 notes export) sit in one menu; re-importing shows externalId dedup and merge policies preserving user edits. Real iNaturalist and eBird CSV exports and WeRead notes `.txt` exports import through the starter pack's own file sources. |
| **Identity** | Cross-source entity collapse via declared + crosswalk ids (movies), and place-match suggestions with confidence that you confirm or reject, and can undo (places). |

## Keyboard, Menus, and Pointer

- **Menu bar** (iPad and Mac): File ▸ Import… (⌘O) and Resolve (⌘↩; on Identity it confirms the first open suggestion), and Go ▸ Paste…Identity (⌘1…⌘5). iPhone keyboards get the same shortcuts as key commands.
- **Context menus**: examples copy their URL or open as a page; feed rows play and copy their link; sources copy their id; place suggestions confirm, reject, or undo.
- **Accessibility**: VoiceOver hears each resolve's outcome rather than every stage; the record card's title is a heading, and its fields read inline in regular width.
