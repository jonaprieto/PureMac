cask "puremac" do
  version "3.3.0"
  sha256 "5ba35fde0b60a645d61edacc8a8b8f198625ea91ac3750c60d41efe22a240a50"

  url "https://github.com/jonaprieto/PureMac/releases/download/v#{version}/PureMac-#{version}.zip"
  name "PureMac"
  desc "macOS app manager and system cleaner (personal fork)"
  homepage "https://github.com/jonaprieto/PureMac"

  # Same token and bundle identifier as upstream's PureMac, so only one of them can be installed;
  # always use the full name jonaprieto/tap/puremac.
  depends_on macos: :ventura

  app "PureMac.app"

  # The build is ad-hoc signed and not notarized, so clear the quarantine flag. Refresh LaunchServices
  # so the Dock/Launchpad icon updates immediately instead of showing a stale cached icon.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-cr", "{{appdir}}/PureMac.app"]
    run "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister",
        args: ["-f", "{{appdir}}/PureMac.app"]
  end

  caveats <<~EOS
    An ad-hoc signature changes with every build, so macOS drops Full Disk Access on each update.
    Remove PureMac from System Settings > Privacy & Security > Full Disk Access, then add it again.
  EOS

  zap trash: [
    "~/Library/Preferences/com.puremac.app.plist",
    "~/Library/Caches/com.puremac.app",
    "~/Library/LaunchAgents/com.puremac.scheduler.plist",
  ]
end
