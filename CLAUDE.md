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

- **Tests:** `./test.sh` — unit tests for the pure logic (`SpaceLayout`, fixture data
  shaped like CGS output: multi-monitor, fullscreen/split-view Spaces, "Main" id, shared
  Spaces, garbage). Run after touching Space/desktop logic.
- **Diagnostics:** menu-bar → *Copy Diagnostics* copies screens / Spaces / windows (no
  titles) — ask users with odd setups for it.
- **No SwiftPM.** This machine's Command Line Tools ship a `libPackageDescription.dylib`
  that's out of sync with the swiftc frontend, so `swift build` fails on any manifest.
  `build.sh` invokes `swiftc` directly on the source list — **add new `.swift` files to
  `build.sh`** (and any new framework with `-framework`).
- **Signing:** built with a stable self-signed identity `"TaskbarPlus Dev"` if present in
  the keychain, else ad-hoc. The stable identity matters: TCC (Accessibility / Screen
  Recording) grants are keyed to the code signature, so ad-hoc's per-build hash change
  makes macOS forget permissions every rebuild. `build.sh` `pkill`s the running instance
  before signing (codesign races on the in-use binary otherwise).
  To create the identity on a new machine: `openssl req -x509` a cert with
  `extendedKeyUsage = critical,codeSigning` and CN `TaskbarPlus Dev`, export it as .p12,
  and `security import id.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign`.
  It does NOT need to be marked trusted (`find-identity` shows `CSSMERR_TP_NOT_TRUSTED`,
  but codesign still uses it). After switching from ad-hoc, `tccutil reset Accessibility
  com.dreamfolks.taskbarplus` and re-grant — a stale ad-hoc grant shows "on" but fails.
- Sandbox **off**, hardened runtime **off** (uses private frameworks + arbitrary app control).

## Permissions

- **Screen Recording** — needed for window *titles* (`kCGWindowName`). Without it the
  switcher falls back to app names. The bar itself works without it.
- **Accessibility** — needed to raise/close a *specific* window (AX API).
- Neither blocks core function. `Permissions` tracks both (polled every 2s): a launch
  alert (suppressible), a ⚠︎ menu-bar icon, and per-permission **Fix…** menu items.
- **Stale grants (the trap):** TCC is keyed to the code signature, so after installing a
  differently-signed build System Settings still shows TaskbarPlus ON but
  `AXIsProcessTrusted()` is false. `Permissions.fix` runs `tccutil reset <service>
  <bundle id>` first, then re-prompts and opens the pane. Screen Recording
  (`CGPreflightScreenCaptureAccess`) only flips after a relaunch → "Restart" item.

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
  app list, the per‑window list, and per‑display "Desk N" labels. Polls every 0.5s +
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

Only six keys (deliberately kept minimal — don't re-add per-section layout options):
- `taskbarOnly` (bool, "Use alongside Dock") — hide pinned/running/folders/Trash (the real
  Dock shows them). The switcher pins right when the Dock is at the bottom, else it's
  centered on the screen. Old configs used the key `splitMode`; it's still read.
- `spaceMode`: `currentSpace` | `allSpaces` | `grouped`. The "Desk N" label on the bar
  is a toggle cycling these ("Desk N" / "All Desks" / "Grouped").
- `groupByApp` (bool) — order the switcher so an app's windows are adjacent (plain
  buttons, no sub-menu); applied in `AppDelegate.distributeWindows`.
- `compact` (bool) — 36pt one-row bar (26pt icons, `maxRows` 1, desktop label beside
  the Apps button) instead of the 60pt two-row bar. Panel geometry comes from the
  instance properties `barHeight` / `iconSize` / `maxRows`.
- `monitors`: `dock` (primary only) | `all`.
- `theme`: `auto` | `light` | `dark`.

The bar layout is fixed in `LayoutConfig.zones` (Start + icons left, switcher
expanding to fill the middle, folders + Trash right).

## Window switcher behaviour

- **Order is creation order** (sorted by CGWindowID, which only increases) and apps by
  launch date — never first-seen or CGWindowList z-order, which reshuffled the bar on
  every Space switch / focus change. `groupByApp` reorders on top of that.
- **Which windows:** enumerated WITHOUT `.optionOnScreenOnly` so minimized windows and
  hidden apps keep a button; scoped by per-window Space id. Off-screen windows only count
  when titled (apps keep untitled 500×500 off-screen helpers → ghost buttons otherwise).
  Same-titled windows merge only when one lies inside the other (Teams overlay).
- **Overflow:** windows that don't fit at `WindowButton.minWidth` go into a trailing
  "» N" `OverflowButton` (menu) — in the flat switcher and in each grouped box.
- **Grouped:** boxes in desktop order plus a last "other" box (`otherDesktop` = 0) for
  windows on fullscreen-app Spaces; widths weighted by window count; when they don't fit,
  the active desktop and its nearest neighbours are kept.
- **Spaces model:** all Space/desktop answers come from `SpaceLayout` — one
  `CGSCopyManagedDisplaySpaces` snapshot per refresh mapped onto screens (by
  `NSScreen.key`). Desktop numbers skip fullscreen/split-view Spaces and run across
  displays; fullscreen hides only that screen's bar; each bar's active desktop and label
  come from its own display.
- **Fullscreen apps always get a button** (any space mode) — each sits on its own Space,
  so it would otherwise vanish from the bar once you leave it. Click → app activation
  switches to its Space.
- **Desktop switching** posts the user's configured "Switch to Desktop N" binding
  (symbolichotkeys 118+N−1), not a hard-coded Ctrl+N; if it's disabled the click just
  raises/activates.

## Maximised windows

macOS only reserves space for its own Dock/menu bar, so `WindowFitter` (driven by
`SpaceWindowService.onWindowsPolled` every poll) shortens windows that start at the top of
the usable area and reach into a bar, via AX `setSize`. It memoises the frame it tried so
an app that refuses/rounds the size isn't fought every 0.5s. Fitted windows stop
`WindowFitter.gap` (6pt) ABOVE the bar, not flush: macOS's resize zone extends outside the
window edge, and flush against the bar the owning app keeps showing the resize cursor
over the bar (fighting the bar's own `NSCursor.arrow`). Don't remove the gap.

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
- **⚠️ Switcher / Trash running off the RIGHT edge (recurring bug — wasted hours MULTIPLE
  times). FIRST check the blur width, NOT the zone constraints.**

  **STEP 1 — always do this first.** Log `contentView?.frame.width` next to the window's
  `frame.width`. If they differ (seen: window `1512` but `contentView` `1681`), THAT is the
  bug and nothing else matters yet. The `NSVisualEffectView` set as `contentView` has
  `translatesAutoresizingMaskIntoConstraints = false`; with autolayout content and no
  explicit size, AppKit grows the window's *content rect* to fit the content's intrinsic
  width, so the layout canvas is wider than the visible window and the right zone (Trash) +
  rightmost chips render in the clipped overflow region. Every zone/switcher constraint can
  be individually satisfied — they're just measured against a too-wide canvas, which makes
  it *look* like a switcher-overflow problem and sends you fiddling constraints for nothing.
  **Fix:** a `.required` **constant** width (+ height) constraint on the blur
  (`blurWidthConstraint`), its constant set to the panel width in `reposition()`. Pinning
  the blur to its superview/themeFrame does NOT work (that grows with the content); only a
  constant clamps it.

  **STEP 2 — only if the blur width is already correct.** The layout model is dead simple:
  the switcher is the ONLY variable-width element. Launcher + icons are fixed and pin LEFT;
  Trash (others) is fixed and pins RIGHT; the switcher fills the gap between them — bounded
  `.required` between `leftZone.trailing + gap` and `rightZone.leading − gap`, with a
  `.defaultHigh` bias toward the configured align edge. The per-button width constraints
  must be *breakable* (`.defaultHigh`) so chips compress instead of overflowing.
  `switcherAvailableWidth()` must return the real on-screen span (screen − flanking zones −
  padding), never the full screen width. Do NOT let a `centerZone.centerX` pin or a
  `.defaultHigh` no-overlap guard be the only thing positioning the right zone — it drifts.

## Private APIs

Declared in `Sources/CSkyLight/include/CSkyLight.h`, linked via `-framework SkyLight`
(`CoreDockSendNotification` resolves through ApplicationServices/HIServices). App Exposé
is triggered with `CoreDockSendNotification("com.apple.expose.front.awake", 0)`. These are
read‑only/notification calls and are far more stable than the (dead) mutating space APIs.
