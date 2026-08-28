# Goes in cyber937/homebrew-tap as Formula/mac-release-verify.rb.
# sha256 is filled in at release time from the tagged tarball:
#   shasum -a 256 <(curl -fsSL "$URL")
class MacReleaseVerify < Formula
  desc "Check a macOS release artifact before you ship it"
  homepage "https://sailmanifest.app"
  url "https://github.com/cyber937/mac-release-verify/archive/refs/tags/v0.1.2.tar.gz"
  sha256 "fe506707102706d09360b8c9e508f541647d837e838c6e2b3f1e92692d8ac638"
  license "MIT"

  def install
    bin.install "bin/mac-release-verify"
  end

  test do
    assert_match "mac-release-verify", shell_output("#{bin}/mac-release-verify --version")
  end
end
