<div align="right">

**English** | [简体中文](README_CN.md)

</div>

<div align="center">

<img src="docs/icon.png" width="140" alt="MiuMiu" />

# MiuMiu

**A native macOS music client, forked from [Kumone](https://github.com/missuo/kumone).**

AppKit + SwiftUI · TCA · APlay · Metal backgrounds

[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue?logo=apple)](#build-and-run)
[![Swift](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](Package.swift)
[![License](https://img.shields.io/badge/license-LGPL--3.0--only-orange)](LICENSE)

[Source branch](https://github.com/CodeEagle/kumone/tree/rewrite/appkit) · [Configuration guide](docs/config-ui.md)

</div>

MiuMiu builds on Kumone's NetEase Cloud Music client and reworks the macOS
application around a native AppKit shell, explicit state management, a new
playback engine, and continuous artwork transitions. This branch focuses on
the experience of browsing, listening, and moving between the mini player and
now playing.

The public application name is **MiuMiu**. The repository, Swift module names,
bundle identifiers, and `~/.config/kumone` configuration directory retain their
existing names for compatibility.

## Changes since the fork

| Area | Changes in this branch |
| --- | --- |
| Architecture | AppKit window and menu lifecycle; shared TCA store; separate Core, TCA, UI, and Shaders modules |
| Playback | APlay engine; cache-aware streaming; CDN host failover; clearer loading, buffering, and source fallback behavior |
| Music sources | Provider abstraction; partial anonymous QQ and Kuwo integrations; configurable self-hosted LX URL resolver |
| Now playing | Classic, immersive, vinyl, and minimal modes; Zen behavior; revised normal/FM controls and metadata layout |
| Motion | Bidirectional Hero transitions for covers, metadata, badges, and controls; consistent scale press feedback |
| Backgrounds | Shared window-level Metal rendering; artwork palettes; optional audio response; shader import and transparency controls |
| macOS integration | Menu bar player, desktop lyrics, native toolbar, configurable local/global shortcuts, media keys and Control Center |
| Customization | YAML screens, themes, bindings, actions, and keymaps with live reload |
| Reliability | Bounded caches and resource lifetimes; navigation, rendering, transport, and native-window regression checks |
| Localization | English and Simplified Chinese coverage for features added in the fork |

### Native application structure

- Replace the macOS SwiftUI scene shell with AppKit-managed windows, toolbars,
  menus, and controllers, while keeping SwiftUI for content.
- Move application and feature state into TCA reducers with dependency clients
  and a shared store. Playback, navigation, settings, and system actions use
  the same state and action flow.
- Separate API/models/playback/storage, feature reducers/views, configurable UI,
  and Metal shaders into independent SwiftPM modules.
- Put search in the native toolbar, refine sidebar and back-button behavior,
  and enforce a minimum main-window size.
- Preserve standard window closing with ⌘W while immersive playback hides the
  traffic lights.

### Playback and streaming

- Replace the original AVPlayer playback path with
  [APlay](https://github.com/CodeEagle/APlay), currently pinned to **2.2.3**.
- Integrate its streaming cache so completed cached audio can be replayed
  without another network fetch. Add storage usage and cache-cleanup controls.
- Add bounded NetEase CDN twin-host failover while preserving signed URLs,
  range requests, and the original cache identity.
- Refine buffering and end-of-stream handling, publish now-playing metadata
  during loading, and pause the outgoing track when a new track is selected.
- Keep configurable audio-source fallback and expose a source badge for
  fallback streams.
- Add a configurable recently-played filter for Personal FM and Heartbeat Mode.

Some transport improvements were adapted from upstream to the APlay/AppKit
architecture. Their scope and validation are recorded in
[upstream macOS ports](docs/upstream-macos-ports.md).

### Music provider abstraction

Features now access music through a provider protocol rather than depending
on NetEase directly. Provider-specific IDs and optional capabilities make
unsupported operations explicit.

| Provider | Implemented scope | Current boundaries |
| --- | --- | --- |
| NetEase | Main account, discovery, library, search, playback, lyrics, FM and playlist workflows | Availability and quality depend on the account and upstream service |
| QQ Music | Anonymous hot keywords, charts, recommended playlists, and lyrics | Login, search, and direct playback are not implemented |
| Kuwo | Anonymous song search, suggestions, selected charts, and playback URL conversion | Playback conversion exposes standard MP3; no account/library management or lyrics |
| LX | Playback URL resolution through a configured self-hosted LX-Source endpoint; also used in the unblock fallback chain | Requires your own endpoint; not a full discovery or account provider |

The QQ, Kuwo, and LX integrations are partial implementations, not feature
parity with NetEase. NetEase requests still use native Swift weapi/eapi
handling; the optional LX resolver uses the service configured by the user.

### Now playing and mini player

- Refine the Liquid Glass mini player into a two-row layout with aligned text,
  status badges, transport controls, and utility buttons.
- Keep VIP and quality badges present, with consistent borders and muted
  unavailable states. Place Like at the far right of the mini player.
- Center the main play/pause button horizontally in both normal playback and
  Personal FM, regardless of the number of surrounding controls.
- Keep title text centered independently of its trailing VIP, quality, and FM
  tags; reserve room for the tags. Allow long artist/album metadata to wrap,
  with links to the corresponding detail pages.
- Refine vinyl presentation and Zen behavior: chrome fades while artwork and
  metadata move toward the center without rebuilding the controls.
- Use translucent black backgrounds for operation buttons to preserve contrast
  on bright shaders.

### Hero transitions and navigation

- Fly artwork between the mini player and now playing, and between cards or
  track artwork and playlist, album, or artist detail headers, in both directions.
- Animate related titles, artists, VIP/quality badges, playback buttons, lyrics
  controls, AirPlay, and FM status alongside the artwork where applicable.
- Hide the appropriate source and destination endpoints during a flight to
  avoid duplicate covers and background flashes.
- Reuse live cached artwork for card transitions; retain progressive
  higher-resolution artwork upgrades for the expanding player cover.
- Interpolate text length, clipping, color, and typography during the return to
  the mini player instead of switching at landing.
- Defer mounting playlist rows until the entering artwork transition finishes
  to avoid blocking its animation with list layout.
- Unify card press feedback with scale animations, and correct return geometry
  for radar playlists and recommended artists.

### Metal backgrounds and readability

- Render a shared Metal backdrop at window level, visible through the sidebar
  and content surfaces, instead of mounting duplicate full-window renderers.
- Build and ease color palettes from track artwork. Imported shaders can react
  to live PCM spectrum and beat information; bundled ShipSwift presets retain
  their original independent animation and colors.
- Support shader selection and import, readable shader names, and a fresh
  presentation host when backgrounds are enabled again.
- Add a 0–100% now-playing shader transparency setting. At 100%, the shader is
  shown without the previous full-page darkening.
- Blur the live shader behind metadata, lyrics, and the whole operation area
  without the gray tint of dark materials. Metadata blur fades gradually into
  the surrounding background.

### System integration and customization

- Provide a menu bar player, floating desktop lyrics, media-key handling,
  Control Center metadata, and a native AirPlay route picker.
- Add configurable local and global shortcuts, native menu key equivalents,
  conflict handling, and shortcut recording.
- Add a configuration-driven UI engine with reusable components, live state
  bindings, parameterized actions, collection rendering, and custom windows.
- Load screen, theme, and keymap overrides from `~/.config/kumone`; reload
  edited files without recompiling. See [the configuration guide](docs/config-ui.md)
  for supported components and examples.

### Reliability and localization

- Bound image caches and diagnostic logs, reuse retained artwork, and release
  shader resources and window-owned state when their owners disappear.
- Improve request cancellation, stale search-result handling, pagination,
  decoding, and atomic shader imports.
- Add tests for cache/transport lifetimes, provider behavior, reducer actions,
  Hero navigation, playback layout, actual GPU blur output, and native window
  commands.
- Localize fork-added settings, shortcuts, source errors, player controls, and
  other UI in English and Simplified Chinese; package both catalogs into app
  targets and validate matching keys and interpolation placeholders.
- Record debugging findings in [lessons learned](docs/lessons-learned.md).

## Everyday features

MiuMiu retains Kumone's core NetEase workflows: QR login, daily recommendations,
Personal FM, Heartbeat Mode, radar and category playlists, charts, new albums,
recommended artists, search, liked songs, saved playlists/albums/artists,
recent playback, cloud disk, playlist management, synchronized lyrics and
translations, quality selection, shuffle/repeat, queue management, scrobbling,
and playback-state restoration.

## Build and run

The primary development target is **macOS 15+**, using **Xcode 26+** with a
Swift 6.2-compatible toolchain. Source builds are the documented installation
path for this fork; upstream Homebrew packages and releases install Kumone.

```bash
git clone --branch rewrite/appkit https://github.com/CodeEagle/kumone.git
cd kumone
swift build
Scripts/build-app.sh debug
open .build/app/MiuMiu.app
```

For a release bundle:

```bash
Scripts/build-app.sh release
```

The default build uses the host architecture. Set `ARCHES="arm64 x86_64"` when
packaging a Universal build. `Scripts/compile_and_run.sh debug` rebuilds and
relaunches the local app.

The existing update infrastructure still references upstream Kumone releases;
this branch does not yet document an independent MiuMiu update feed, signed
release, or notarization pipeline.

### Xcode and other Apple platforms

The root XcodeGen specification also includes iOS 17+ and visionOS 1.0+ targets.
The detailed UI work described above is centered on macOS; inclusion of other
platform targets does not imply identical presentation or release readiness.

```bash
xcodegen generate --spec project.yml
open MiuMiu.xcodeproj
```

Choose `KumoneMac`, `KumoneiOS`, or `KumoneVision`. Internal target names are
retained. Shared CarPlay code is in `Sources/KumoneTCA/iOS/CarPlay`; the legacy
`ios/` build setup provides `make configure` / `make configure-carplay` for its
optional capability. CarPlay remains disabled by default and requires the
appropriate Apple entitlement and signing profile.

## Architecture

```text
Apps/
├── Mac/                 # AppKit application, windows, menus, toolbar, integrations
├── iOS/                 # UIKit scene entry point
├── UIKitCommon/         # Shared UIKit application plumbing
└── Vision/              # visionOS entry point
Sources/
├── KumoneCore/          # Providers, APIs, models, APlay integration, caches, rendering
├── KumoneTCA/           # Reducers, dependency clients, SwiftUI screens, Hero system
├── KumoneUI/            # YAML UI engine, bindings, actions, themes, components
├── KumoneShaders/       # Metal shaders, shared uniforms, bundled presets
└── Kumone/Resources/    # English and Simplified Chinese catalogs
Tests/                   # Core, TCA, UI-engine, and native macOS checks
```

## Development checks

```bash
swift test
python3 Scripts/check-localizations.py
```

Run the localization check after a build so compiler-extracted strings are
available. Native window and Metal checks need the corresponding macOS runtime.

## Credits and license

MiuMiu is a fork of **[Kumone](https://github.com/missuo/kumone)** by **missuo**,
not a from-scratch implementation. Thanks to the upstream project and its
contributors for the client and the continuing improvements adapted here.

- [APlay](https://github.com/CodeEagle/APlay) — playback engine and streaming cache.
- [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) — application state and effects.
- ShipSwift — original bundled shader presets.
- [YesPlayMusic](https://github.com/qier222/YesPlayMusic) and [kaset](https://github.com/sozercan/kaset) — upstream references for music-client behavior, design, and packaging.
- [UnblockNeteaseMusic/server](https://github.com/UnblockNeteaseMusic/server) — upstream reference for source matching and fallback.
- [LyricsX](https://github.com/ddddxxx/LyricsX) — upstream reference for desktop lyrics.
- [Sonimbus](https://github.com/gee1k/sonimbus) — a related NetEase client for Apple TV.

The existing [LGPL-3.0-only license](LICENSE) is retained, with [GPL-3.0](COPYING)
text included alongside it. Music data and rights belong to their respective
platforms and rights holders.
