cask "puremac" do
  version "3.3.0-1"
  sha256 "66d1f451a8dbfdcb9846a09f304dd585838fb441ef269a8630be954ba1bc1a85"

  url "https://github.com/jonaprieto/PureMac/releases/download/fork-#{version}/PureMac-#{version}.zip"
  name "PureMac"
  desc "macOS app manager and system cleaner (personal fork)"
  homepage "https://github.com/jonaprieto/PureMac"

  # Same token and bundle identifier as upstream's PureMac, so only one of them can be installed;
  # always use the full name jonaprieto/tap/puremac.
  depends_on macos: :ventura

  app "PureMac.app"

  # The build is ad-hoc signed and not notarized, so clear the quarantine flag.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-cr", "{{appdir}}/PureMac.app"]
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
