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

### A theme

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
`uparrow` `downarrow` `f1`…`f12`. Matching is lenient about *extra*
held modifiers: `cmd+l` still fires with `cmd+shift+l`.

## Expressions: `${path}`

Any string/number/flag prop may be `${path}` instead of a literal. The
path is resolved against the binding table at render time, inside the
view's observation frame — the view rebuilds when the state behind it
changes. Unknown paths resolve to nothing (empty string, hidden),
never crash. There is deliberately no expression *language*: if you
need logic, the answer is a new binding in the app's table, not more
grammar in YAML.

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
| `player.shuffleEnabled` | flag | shuffle on |
| `player.repeatMode` | string | `off` / `all` / `one` |
| `player.isBuffering` | flag | stream buffering |
| `lyrics.currentLine` | string | the line the desktop sheet shows |
| `lyrics.lineCount` | number | how many lines exist |
| `app.nowPlayingOpen` | flag | immersive page presented |
| `app.shaderName` | string | active shader id |

## Table 3 — Actions

What a `Button`/slider/keymap entry invokes:

| Verb | Argument | Effect |
| --- | --- | --- |
| `player.togglePlayPause` | — | play or pause |
| `player.next` / `player.previous` | — | skip either way |
| `player.seek` | number | jump the playhead (slider commits) |
| `player.setVolume` | number | 0…1 |
| `player.toggleShuffle` | — | flip shuffle |
| `player.cycleRepeatMode` | — | off → all → one |
| `player.toggleLyricsPanel` | — | lyrics side panel |
| `player.toggleQueuePanel` | — | queue side panel |
| `app.presentScreen` | string | open a screen by name as a window |
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
