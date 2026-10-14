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

5. **Grant permissions.** On first launch Taskbar Plus explains what it needs and offers
   **Fix…**, which opens the right System Settings page — just switch Taskbar Plus on:
   - **Accessibility** — to fit maximised windows above the bar and raise/close specific
     windows from the switcher.
   - **Screen Recording** — to read window *titles*. (The bar still works without it,
     showing app names instead of titles.)

   While a permission is missing, the menu-bar icon shows **⚠︎** and its menu has a
   **Fix…** item for it, plus **Restart Taskbar Plus** (Screen Recording only applies
   after a restart).

   **Upgrading and something stopped working?** macOS ties permissions to the app's
   signature, so after an upgrade Taskbar Plus can look switched *on* in System Settings
   while the grant no longer applies. Use **Fix…** from the menu-bar icon — it clears the
   stale entry so you can switch it on again.

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

Settings are in the menu-bar icon → **Preferences**:

- **Dock** — *Replace Dock* (the bar shows app icons, folders and Trash) or *Use
  alongside Dock* (just Start + window buttons; the real Dock shows the apps).
- **Height** — standard (two rows of window buttons) or compact (one row, shorter bar).
- **Windows shown** — this desktop, all desktops, or grouped by desktop. Clicking the
  Desktop label on the bar cycles this too.
- **Group windows by app** — keep an app's windows next to each other on the bar.
- **Monitors** — main monitor only, or every monitor.
- **Theme** — auto, light or dark.
- **Start at login.**

They're persisted to `~/.taskbarplus.json`. Maximised windows are automatically
shortened to stop at the bar's top edge (needs Accessibility permission).

## Building from source

No SwiftPM — build with `swiftc` directly:
```sh
./build.sh            # compiles, assembles TaskbarPlus.app, code-signs it
./release.sh          # builds + packages dist/TaskbarPlus-<version>.zip for release
```
See [CLAUDE.md](CLAUDE.md) for architecture and the hard-won macOS constraints.
