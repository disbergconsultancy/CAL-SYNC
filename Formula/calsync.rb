cask "calsync" do
  version "1.0.1"
  sha256 "4867c7217a251baf71559b8b0e6bd2076ba51dff86e405a0a63a49bd7f19c640"

  url "https://github.com/disbergconsultancy/CAL-SYNC/releases/download/v#{version}/CalSync-#{version}.zip"
  name "CalSync"
  desc "macOS menu bar app for calendar synchronization"
  homepage "https://github.com/disbergconsultancy/CAL-SYNC"

  # Requires macOS 13 (Ventura) or later
  depends_on macos: ">= :ventura"

  app "CalSync.app"

  postflight do
    # Remove quarantine attribute to prevent "damaged app" warning
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/CalSync.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/com.disbergconsultancy.CalSync.plist",
    "~/Library/Application Support/CalSync",
  ]

  caveats <<~EOS
    CalSync is not notarized by Apple. If you see "app is damaged" warning:
      xattr -cr /Applications/CalSync.app
  EOS
end
