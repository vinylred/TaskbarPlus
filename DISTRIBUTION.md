# Distributing Taskbar Plus

Taskbar Plus links private system frameworks (SkyLight/CGS) and runs without the hardened
runtime, so it **cannot** go through the Mac App Store or Apple notarization. It is
distributed ad-hoc-signed, like yabai / sketchybar. Distribution = GitHub Releases, with
an optional Homebrew Cask for a one-command install.

## One-time setup

1. Create a GitHub repo for the source (e.g. `github.com/vinylred/TaskbarPlus`), add it as a
   remote, and push `main` + tags:
   ```sh
   git remote add origin git@github.com:vinylred/TaskbarPlus.git
   git push -u origin main
   git push --tags
   ```
2. (For Cask) create a second repo named `homebrew-tap` and copy `Casks/taskbar-plus.rb`
   into its `Casks/` directory. Users then install with:
   ```sh
   brew install --cask vinylred/tap/taskbar-plus
   ```

## Each release

```sh
./release.sh                       # builds + packages dist/TaskbarPlus-<version>.zip,
                                   # prints the SHA-256
```
Then:
1. Create a GitHub Release for the tag (e.g. `v1.2.2`) and **attach the zip**.
2. Update `version` and `sha256` in `Casks/taskbar-plus.rb`, and `vinylred/TaskbarPlus` in its
   URLs. Commit/push the tap repo.

Bump the version in `Resources/Info.plist` before tagging so the app, tag, and zip name
all agree.

## What users do

See [README.md](README.md). Either:
- **Manual:** download the zip, move to /Applications, run
  `xattr -dr com.apple.quarantine /Applications/TaskbarPlus.app`, open, grant permissions.
- **Homebrew:** `brew install --cask vinylred/tap/taskbar-plus` (handles the move + clears
  quarantine automatically), then grant permissions.

## What CANNOT be automated

Accessibility and Screen Recording are TCC permissions — they require an explicit user
approval in System Settings on first run, for any app, regardless of install method. No
cask, entitlement, or script can grant them silently. The Cask only removes the file-move
and quarantine steps, not the permission grants.
