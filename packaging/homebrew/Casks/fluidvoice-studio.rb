cask "fluidvoice-studio" do
  version "1.6.13"
  # The release workflow publishes this asset. Update the checksum from
  # `shasum -a 256 FluidVoice-Studio-<version>.dmg` when cutting a release.
  sha256 :no_check

  url "https://github.com/agentik-os/FluidVoice-Studio/releases/download/v#{version}/FluidVoice-Studio-#{version}.dmg"
  name "FluidVoice Studio"
  desc "FluidVoice fork with paired remote microphones and a Screen Sharing hotkey"
  homepage "https://github.com/agentik-os/FluidVoice-Studio"

  app "FluidVoice.app"

  uninstall quit: "com.FluidApp.app",
            launchctl: "com.FluidApp.app"

  zap trash: [
    "~/Library/Application Support/FluidVoice/studio-identity.json",
  ]
end
