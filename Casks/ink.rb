cask "ink" do
  version "1.0.0"
  sha256 "f42551caeab7d4f6fefcc56a86531a7029225dcc8300e51ac7ab9b19e6bde513"

  url "https://github.com/guebin/ink/releases/latest/download/Ink.dmg",
      verified: "github.com/guebin/ink/"
  name "Ink"
  desc "Infinite-canvas drawing board with Markdown and LaTeX cards"
  homepage "https://github.com/guebin/ink"

  depends_on macos: :monterey

  app "Ink.app"

  # The build is ad-hoc signed, so macOS would refuse to open it while the
  # download flag is set. Homebrew adds that flag; take it back off.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Ink.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/com.cgb.ink.plist",
    "~/Library/Saved Application State/com.cgb.ink.savedState",
    "~/Library/WebKit/com.cgb.ink",
  ]
end
