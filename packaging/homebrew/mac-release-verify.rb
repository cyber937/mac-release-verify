# Goes in cyber937/homebrew-tap as Formula/mac-release-verify.rb.
# sha256 is filled in at release time from the tagged tarball:
#   shasum -a 256 <(curl -fsSL "$URL")
class MacReleaseVerify < Formula
  desc "Check a macOS release artifact before you ship it"
  homepage "https://sailmanifest.app"
  url "https://github.com/cyber937/mac-release-verify/archive/refs/tags/v0.1.3.tar.gz"
  sha256 "1370b66c347f54ce61d2cf9b543953b0c74bc0f823d9153c38ad341c2497c54a"
  license "MIT"

  def install
    bin.install "bin/mac-release-verify"
  end

  test do
    assert_match "mac-release-verify", shell_output("#{bin}/mac-release-verify --version")
  end
end
