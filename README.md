# Taskbar Plus

A Windows-style taskbar for macOS: a Dock-replacement bar of pinned/running app icons
plus a per-window task switcher, scoped to the current macOS Space. Runs as a menu-bar
agent (no Dock icon of its own).

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon.

## Install

> **Note on signing.** Taskbar Plus uses private system frameworks and runs without the
> hardened runtime, so it can't ship through the Mac App Store or Apple notarization (the
> same constraints as tools like yabai). It's distributed ad-hoc-signed. macOS will block
> it on first launch until you clear the download quarantine — that's the one extra step
> below.

1. **Download** `TaskbarPlus-<version>.zip` from the
   [Releases](../../releases) page and unzip it.

2. **Move** `TaskbarPlus.app` to `/Applications`.

3. **Clear the quarantine flag** (so Gatekeeper will let it run). In Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/TaskbarPlus.app
   ```
   (Without this you'll get *"TaskbarPlus is damaged / can't be opened"* — it isn't
   damaged; that's Gatekeeper blocking an un-notarized app.)

4. **Open it:**
   ```sh
   open /Applications/TaskbarPlus.app
   ```

5. **Grant permissions** when prompted (System Settings → Privacy & Security):
   - **Accessibility** — to raise/close specific windows from the switcher.
   - **Screen Recording** — to read window *titles*. (The bar still works without it,
     showing app names instead of titles.)

   After granting, quit and reopen the app (or toggle it off/on in the permission list)
   so the grants take effect.

6. **(Optional) Start at login:** open Preferences from the menu-bar icon and enable
   *Start at login*.

## Updating

Replace the app and clear quarantine again:
```sh
xattr -dr com.apple.quarantine /Applications/TaskbarPlus.app
```
Your settings live in `~/.taskbarplus.json` and are preserved across updates.

## Uninstall

```sh
rm -rf /Applications/TaskbarPlus.app
rm -f ~/.taskbarplus.json
```
Then remove it from System Settings → Privacy & Security → Accessibility / Screen Recording.

## Configuration

Settings are in the menu-bar icon → **Preferences** (layout zones, alignment, theme,
monitors, grouped-desktop ordering, split mode). They're persisted to
`~/.taskbarplus.json`.

## Building from source

No SwiftPM — build with `swiftc` directly:
```sh
./build.sh            # compiles, assembles TaskbarPlus.app, code-signs it
./release.sh          # builds + packages dist/TaskbarPlus-<version>.zip for release
```
See [CLAUDE.md](CLAUDE.md) for architecture and the hard-won macOS constraints.
