cask "ink" do
  version "1.0.1"
  sha256 "e842af47fa37bb8f8a97ec9e77253890a1f0f6d66c194995d9a8637fccb52f26"

  url "https://github.com/guebin/ink/releases/download/v#{version}/Ink.dmg",
      verified: "github.com/guebin/ink/"
  name "Ink"
  desc "Infinite-canvas drawing board with Markdown and LaTeX cards"
  homepage "https://github.com/guebin/ink"

  depends_on macos: :monterey
  depends_on arch: :arm64

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
