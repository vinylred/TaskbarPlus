# Homebrew Cask for Taskbar Plus.
#
# This belongs in a TAP repo named `homebrew-tap` (github.com/vinylred/homebrew-tap),
# under its `Casks/` directory. Users then install with:
#
#   brew install --cask vinylred/tap/taskbar-plus
#
# Before publishing each release, update `version` and `sha256` (run:
#   shasum -a 256 dist/TaskbarPlus-<version>.zip
# ), and make sure the GitHub Release for that tag has the matching zip attached.
cask "taskbar-plus" do
  version "1.3.2"
  sha256 "78b067623899b3e9637ead28de3bf55c7cd7f81ddb276243b18b7af35619fdf7"

  url "https://github.com/vinylred/TaskbarPlus/releases/download/v#{version}/TaskbarPlus-#{version}.zip"
  name "Taskbar Plus"
  desc "Windows-style taskbar and per-Space window switcher for macOS"
  homepage "https://github.com/vinylred/TaskbarPlus"

  # The app is ad-hoc-signed (private frameworks + no hardened runtime → can't be
  # notarized). `auto_updates false` / no `livecheck` since releases are manual.
  depends_on macos: ">= :sonoma"

  app "TaskbarPlus.app"

  # Homebrew strips the download quarantine automatically, so users skip the manual
  # `xattr -dr com.apple.quarantine` step. (It still cannot grant TCC permissions —
  # Accessibility and Screen Recording must be approved by the user in System Settings.)
  caveats <<~EOS
    Taskbar Plus needs two permissions, granted once in
    System Settings → Privacy & Security:
      • Accessibility    — to raise/close specific windows
      • Screen Recording — to read window titles (optional; falls back to app names)

    After granting them, quit and reopen Taskbar Plus so the grants take effect.
  EOS

  uninstall quit: "com.dreamfolks.taskbarplus"

  zap trash: "~/.taskbarplus.json"
end
