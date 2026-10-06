# Config-Driven UI — the public interface

Kumone's player surface is YAML. A screen is a declarative tree, and
everything dynamic flows through three public tables the app publishes:
**components** (what can appear), **bindings** (what it can read), and
**actions** (what it can do). A keymap reaches the same verbs a button
does. Editing any file below is live: a directory watcher reloads it,
no recompile, no restart.

This is the Linux-style surface: the app ships its defaults, and your
`~/.config` overrides them per file.

## File layout

| Where | What |
| --- | --- |
| bundled defaults | `KumoneUI` module resources: `screens/*.yaml` |
| `~/.config/kumone/screens/preview.yaml` | one screen per file; the file name *is* the screen name |
| `~/.config/kumone/theme.yaml` | design tokens and class rules |
| `~/.config/kumone/keymap.yaml` | shortcuts → actions |

User files win over bundled ones **per file**: drop a `preview.yaml`
and the bundled one is ignored; drop `keymap.yaml` and the whole default
keymap is replaced (an empty one disables every shortcut). Screens
merge by name — a user `mini.yaml` adds a screen, it cannot remove one.

### A screen

```yaml
root:
  type: VStack
  class: [chrome]
  spacing: 18
  children:
    - type: Text
      text: ${player.title}
      fontSize: 22
      color: "#F2F2F5"
    - type: Button
      action: player.togglePlayPause
      children:
        - type: Text
          text: ❚❚
```

Every node takes: `type` (the component), `class` (theme rules, see
below), `props` (written inline as YAML keys), `children`, and
`visible` — a boolean or a binding (`visible: ${player.hasTrack}`);
unknown bindings hide, which is the safe direction.

### Themes

```yaml
tokens:
  accent: "#E8567A"

styles:
  chrome:
    background: "#1C1C22"
    cornerRadius: 16
```

Class rules apply in the order the node lists them, the node's own props
override them, and `token(name)` inside a string expands to a token.

Themes are a *library*, not a single file: `theme.yaml` is the nameless
default, `theme-<name>.yaml` is another one (`theme-aurora.yaml` → the
theme `aurora`). Drop `theme-<name>.yaml` in your config directory and it
appears in `app.themeNames` — no registration. Switching is live: the
`app.setTheme` verb (argument: the theme name) re-renders every screen
with the new sheet, and the choice persists across launches. A theme
switcher in config is a ForEach over `app.themeNames` whose buttons pass
`argument: ${item}` (the mini screen ships one).

### A keymap

```yaml
space: player.togglePlayPause
cmd+l: player.toggleLyricsPanel
cmd+shift+q: player.toggleQueuePanel
rightarrow: player.next
```

Modifier aliases: `cmd`/`command`, `opt`/`option`/`alt`,
`ctrl`/`ctl`/`control`, `shift`. Key names are single characters or
`space` `return` `escape` `tab` `delete` `leftarrow` `rightarrow`
`uparrow` `downarrow` `f1`…`f12`. The media keys are nameable too —
`media-play` `media-next` `media-previous` `volumeup` `volumedown`
`mute` — they arrive as system-defined events, and volume keys stay
unbound by default so macOS keeps them. Matching is lenient about
*extra* held modifiers: `cmd+l` still fires with `cmd+shift+l`.

## Expressions: `${path}`

Any string/number/flag prop may be `${path}` instead of a literal. The
path is resolved against the binding table at render time, inside the
view's observation frame — the view rebuilds when the state behind it
changes. Unknown paths resolve to nothing (empty string, hidden),
never crash. There is deliberately no expression *language*: if you
need logic, the answer is a new binding in the app's table, not more
grammar in YAML.

### Item scope

A `ForEach` opens a scope for the element it is stamping: inside the
repeated child, `${item}` is the element itself (when the list holds
strings) and `${item.title}` / `${item.artist}` / … address its fields
(when it holds mappings). Everything outside `item.` still resolves
against the app's state, so one row can mix `${item.title}` and
`${player.title}`.

## Table 1 — Components

| Component | Props (besides `visible`/`class`) | Notes |
| --- | --- | --- |
| `VStack` / `HStack` | `alignment`, `spacing`, `padding` | alignment: `leading`/`center`/`trailing` (V) or `top`/`center`/`bottom`/baselines (H) |
| `ZStack` | — | children layer back to front |
| `Spacer` | `minLength` | expands |
| `Text` | `text`, `fontSize`, `fontWeight`, `color` | weight: `bold`/`semibold`/`light`/`thin`; color `#RRGGBB` |
| `Container` | `cornerRadius`, `padding`, `background` | the panel primitive; children stack vertically |
| `Button` | `action`, `argument` | children become the label; `argument` is a literal or binding the verb receives |
| `ProgressSlider` | `value`, `duration`, `action`, `color` | drag-held locally, commits the position as the action's argument on release |
| `Artwork` | `url`, `size`, `cornerRadius` | remote album art; placeholder while loading or missing |
| `ForEach` | `items`, `spacing` | repeats its first child once per element of a list binding; `${item}` / `${item.field}` in that child resolves to the element |
| `LyricView` | `lines`, `currentIndex`, `fontSize`, `activeColor`, `inactiveColor`, `placeholder`, `alignment` | a whole lyric sheet: the current line highlighted (colors as `#RRGGBB`) and held centered; it is a *composite* component — a view written in Swift, because "which row is current" is a comparison the grammar does not have |
| `SpectrumBars` | `barWidth`, `barHeight`, `spacing`, `color` | live audio spectrum |

Any node type not in this table renders nothing; a screen survives a
missing component.

## Table 2 — Bindings

Read-only, resolved per render:

| Path | Type | Meaning |
| --- | --- | --- |
| `player.title` | string | current track name |
| `player.artist` | string | first artist |
| `player.album` | string | album name |
| `player.artworkURL` | string | album art URL |
| `player.isPlaying` | flag | currently playing |
| `player.isPaused` | flag | track loaded, not playing |
| `player.hasTrack` | flag | anything loaded |
| `player.progress` | number | playhead, seconds |
| `player.duration` | number | track length, seconds |
| `player.volume` | number | 0…1 |
| `player.progressClock` / `player.durationClock` | string | position and length pre-formatted (`4:07`, `1:04:07`); config cannot transform a number, so the clock is a binding |
| `player.shuffleEnabled` | flag | shuffle on |
| `player.repeatMode` | string | `off` / `all` / `one` |
| `player.isBuffering` | flag | stream buffering |
| `player.upcomingTracks` | list<mapping> | what is coming: each item has `title`, `artist`, `artworkURL`, `duration` (capped at 50) |
| `lyrics.currentLine` | string | the line the desktop sheet shows |
| `lyrics.lineCount` | number | how many lines exist |
| `lyrics.currentIndex` | number | which line is live (-1 = none) |
| `lyrics.lines` | list<string> | every lyric line, for a ForEach |
| `app.nowPlayingOpen` | flag | immersive page presented |
| `app.shaderName` | string | active shader id |
| `app.themeName` | string | the theme every screen renders with |
| `app.themeNames` | list<string> | every theme file found, sorted — for a switcher |

## Table 3 — Actions

What a `Button`/slider/keymap entry invokes:

| Verb | Argument | Effect |
| --- | --- | --- |
| `player.togglePlayPause` | — | play or pause |
| `player.next` / `player.previous` | — | skip either way |
| `player.seek` | number | jump the playhead (slider commits) |
| `player.setVolume` | number | 0…1 |
| `player.volumeUp` / `player.volumeDown` | — | step 0.05 either way |
| `player.toggleShuffle` | — | flip shuffle |
| `player.cycleRepeatMode` | — | off → all → one |
| `player.toggleLyricsPanel` | — | lyrics side panel |
| `player.toggleQueuePanel` | — | queue side panel |
| `app.presentScreen` | string | open a screen by name as a window |
| `app.setTheme` | string | switch every screen to that theme |
| `app.presentNowPlaying` / `app.dismissNowPlaying` | — | immersive page |

Unknown verbs do nothing visibly (a DEBUG log names them); a typo never
breaks a screen.

## Extending the surface

All three tables are meant to grow. In app code:

```swift
// A component (the engine never enumerates them; registration *is* the list)
ComponentRegistry.register("CircularSpectrum") { node, context in ... }

// A binding (the app's PathBindingResolver: one line, one getter)
"player.hasLiked": { .flag(...) }

// An action (ActionRegistry: the counterpart of a binding — it mutates)
registry.register("player.setVolume") { argument in ... }
```

A future plugin will publish the same three things through the same
channels; there is no second-class path.
