# Cask for the tap niklas-schmidt-dev/homebrew-tap. update-cask.sh fills in version and sha256
# for a release.
cask "mobdev" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/niklas-schmidt-dev/mobdev/releases/download/mac-v#{version}/Mobdev.dmg"
  name "Mobdev"
  desc "Lets AI agents and people drive iPhones, iOS simulators and Android devices"
  homepage "https://mobdev.sh/"

  livecheck do
    url :url
    regex(/^mac-v(\d+(?:\.\d+)+)$/i)
    strategy :github_releases
  end

  auto_updates true
  depends_on macos: :tahoe

  app "Mobdev.app"
  # A script rather than a symlink to the app's executable: Mobdev finds its app bundle from the
  # path it was started with, and `mobdev mcp` and `mobdev call` need it to reach the app.
  binary "mobdev.wrapper.sh", target: "mobdev"

  preflight_steps do
    write_file "mobdev.wrapper.sh", <<~EOS
      #!/bin/sh
      exec '{{appdir}}/Mobdev.app/Contents/MacOS/Mobdev' "$@"
    EOS
  end

  zap trash: [
    "~/Library/Application Support/dev.mobdev.mac",
    "~/Library/Caches/dev.mobdev.mac",
    "~/Library/HTTPStorages/dev.mobdev.mac",
    "~/Library/Preferences/dev.mobdev.mac.plist",
    "~/Library/Saved Application State/dev.mobdev.mac.savedState",
  ]
end
