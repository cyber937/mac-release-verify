# Goes in cyber937/homebrew-tap as Formula/mac-release-verify.rb.
# sha256 is filled in at release time from the tagged tarball:
#   shasum -a 256 <(curl -fsSL "$URL")
class MacReleaseVerify < Formula
  desc "Check a macOS release artifact before you ship it"
  homepage "https://sailmanifest.app"
  url "https://github.com/cyber937/mac-release-verify/archive/refs/tags/v0.1.4.tar.gz"
  sha256 "06a5d74daea99ca8e0881953a37220b30c29270ac0d2e3d9368a9fae65a710f9"
  license "MIT"

  def install
    bin.install "bin/mac-release-verify"
  end

  test do
    assert_match "mac-release-verify", shell_output("#{bin}/mac-release-verify --version")
  end
end
