# Taskbar Plus

A macOS agent app (`LSUIElement`, no Dock icon of its own) that draws a **Windows‑style
taskbar** along the bottom of every screen: a Dock‑replacement bar of pinned/running app
icons plus a Win95‑style **per‑window task switcher**, scoped to the current macOS Space.

## Build & run

```sh
./build.sh          # compiles with swiftc, assembles TaskbarPlus.app, code-signs it
open ./TaskbarPlus.app
TBP_DEBUG=1 ./TaskbarPlus.app/Contents/MacOS/TaskbarPlus   # verbose logging to stderr
TBP_BORDERS=1 …      # draw colored debug borders around the layout zones
```

- **No SwiftPM.** This machine's Command Line Tools ship a `libPackageDescription.dylib`
  that's out of sync with the swiftc frontend, so `swift build` fails on any manifest.
  `build.sh` invokes `swiftc` directly on the source list — **add new `.swift` files to
  `build.sh`** (and any new framework with `-framework`).
- **Signing:** built with a stable self-signed identity `"TaskbarPlus Dev"` if present in
  the keychain, else ad-hoc. The stable identity matters: TCC (Accessibility / Screen
  Recording) grants are keyed to the code signature, so ad-hoc's per-build hash change
  makes macOS forget permissions every rebuild. `build.sh` `pkill`s the running instance
  before signing (codesign races on the in-use binary otherwise).
- Sandbox **off**, hardened runtime **off** (uses private frameworks + arbitrary app control).

## Permissions

- **Screen Recording** — needed for window *titles* (`kCGWindowName`). Without it the
  switcher falls back to app names. The bar itself works without it.
- **Accessibility** — needed to raise/close a *specific* window (AX API).
- Neither blocks core function; both are requested at launch via `WindowControl`.

## Architecture

`main.swift` (AppDelegate) owns one `TaskbarPanel` **per screen** and wires the services:

```
SpaceWindowService ──onChange(apps)──▶ DockModelService ──onChange(items)──▶ panel.update(items:)
        │           ──onWindowsChange(windows)──────────────────────────────▶ panel.updateWindows(:)
        └           ──onDesktopChange(names)───────────────────────────────▶ panel.updateDesktop(:)
```

- **`SpaceWindowService`** — the engine. Enumerates windows via `CGWindowListCopyWindowInfo`,
  maps them to Spaces via private CGS calls (`CGSCopyManagedDisplaySpaces`,
  `CGSCopySpacesForWindows` — declared in the `CSkyLight` C shim). Emits the current‑Space
  app list, the per‑window list, and per‑display "Desktop N" labels. Polls every 0.5s +
  reacts to `NSWorkspace` notifications (debounced); Space changes refresh immediately.
- **`DockModelService`** — reads the real Dock's `com.apple.dock` prefs (`persistent-apps`,
  `persistent-others`) into pinned launchers + folders + Trash, merges in running state
  (dedupe pinned↔running), emits `[DockItem]`. Icons cached by path. Watches `~/.Trash`
  for the empty/full icon.
- **`TaskbarPanel`** — the borderless non‑activating `NSPanel` (`.statusBar` level,
  `.canJoinAllSpaces`). Lays sections into three zones (left/center/right) per config,
  renders `DockIconView`s and `WindowButton`s, the launcher, and the task switcher.
- **`LayoutConfig`** — loads/saves `~/.taskbarplus.json`.
- **`PreferencesController`** — status‑bar menu → Preferences window; live‑applies layout,
  theme, monitors, and the "Start at login" toggle (`LoginItem` / `SMAppService`).

## Configuration — `~/.taskbarplus.json`

Sections: `launcher`, `pinned`, `running`, `others` (folders+Trash), `switcher`.
Each takes a zone string or an object `{zone, expand, align}`:
- `zone`: `left` | `center` | `right`
- `expand`: `left` | `right` — stretch to fill toward that edge
- `align`: `left` | `center` | `right` — position content within the area

Top‑level keys: `theme` (`auto`/`light`/`dark`), `monitors` (`dock`/`all`),
`spaceMode` (`currentSpace`/`allSpaces`/`grouped`). The "Desktop N" label is a **toggle**
cycling those three space modes.

## Hard‑won constraints (do NOT relearn these)

- **Programmatic Space switching is dead on macOS 26.** `CGSManagedDisplaySetCurrentSpace`,
  `CGSShowSpaces`/`HideSpaces`, and the `SLS`‑prefixed variants are all no‑ops (same
  lockdown that broke yabai). To switch Spaces, **synthesize the Ctrl+N shortcut** —
  see `DesktopSwitcher` and `memory/space-switch-via-keystroke.md`. A window on another
  Space is also invisible to the AX API, so the click chain is: post Ctrl+<desktop> →
  wait ~0.45s → AX‑raise the now‑visible window.
- **CGS `Copy` functions are `CF_RETURNS_RETAINED` in the shim → ARC frees them.** Do NOT
  add manual `CFRelease` (double‑free crash). The earlier "memory leak" review that
  flagged these was wrong.
- **Tooltips:** the bar is a non‑key panel, so AppKit's built‑in `.toolTip` never fires.
  Tooltips are custom (`TooltipWindow` + tracking areas), shown immediately like the Dock.
- **Per‑monitor:** running‑apps/pinned/folders/Trash are identical on every monitor; only
  the window switcher is per‑monitor. (Don't add a per‑monitor running filter — see
  `memory/no-per-monitor-running-filter.md`.)
- **Primary display id:** `CGSCopyManagedDisplaySpaces` keys the primary display as the
  literal `"Main"`, not a UUID — match accordingly when mapping to `NSScreen`.
- Panels are recreated on display/config change; they `close()` (with
  `isReleasedWhenClosed = false`) and remove observers in `deinit` so they don't leak.
- **Switcher running off the RIGHT edge (recurring bug — fixed several times):** the
  switcher/right zone is an `NSStackView` of fixed-width buttons whose intrinsic content
  width can exceed the space available. The fix has TWO required parts together:
  (1) the right zone's `trailing` is pinned to the panel's right edge at `.required`, AND
  (2) it has a `.required` left FLOOR (`rightZone.leading >= leftZone.trailing + gap`) so
  content shrinks/caps instead of overflowing; the per-button width constraints must be
  *breakable* (`.defaultHigh`) so they yield. Do NOT let a `centerZone.centerX` pin or a
  `.defaultHigh` no-overlap guard be the only thing positioning the right zone — that lets
  it drift off-screen. `switcherAvailableWidth()` must return the real on-screen span
  (screen − flanking zones − padding), never the full screen width. If the right zone's
  rendered `frame.maxX` exceeds the panel width, this is the bug — check those constraints.

## Private APIs

Declared in `Sources/CSkyLight/include/CSkyLight.h`, linked via `-framework SkyLight`
(`CoreDockSendNotification` resolves through ApplicationServices/HIServices). App Exposé
is triggered with `CoreDockSendNotification("com.apple.expose.front.awake", 0)`. These are
read‑only/notification calls and are far more stable than the (dead) mutating space APIs.
