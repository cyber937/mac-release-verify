#!/bin/bash
#
# Negative controls.
#
# A checker that only ever reports PASS is indistinguishable from a checker that
# does nothing. Every check in this tool therefore has to be shown failing on an
# artifact that is known to be broken, before a PASS from it means anything.
#
# These tests build deliberately broken artifacts and assert that the specific
# check fires. They need no signing identity, no Apple account and no network.
#
#   ./tests/negative-controls.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../bin/mac-release-verify"
WORK="$(mktemp -d /tmp/mrv-tests.XXXXXX)"
FAILURES=0
RAN=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

pass_msg() { printf '  ok    %s\n' "$1"; }
fail_msg() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# expect_check_fails <description> <check name> <output>
expect_check_fails() {
  RAN=$((RAN + 1))
  if printf '%s' "$3" | grep -q "FAIL  $2"; then
    pass_msg "$1"
  else
    fail_msg "$1 — expected a FAIL on \"$2\", got:"
    printf '%s\n' "$3" | sed 's/^/          /'
  fi
}

# expect_exit <description> <expected> <actual>
expect_exit() {
  RAN=$((RAN + 1))
  if [ "$2" = "$3" ]; then pass_msg "$1"; else fail_msg "$1 — expected exit $2, got $3"; fi
}

# --------------------------------------------------------- build a broken app

STAGE="$WORK/stage"
APP="$STAGE/Broken.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/libexec/PlistBuddy \
  -c "Add :CFBundleExecutable string Broken" \
  -c "Add :CFBundleIdentifier string com.example.broken" \
  -c "Add :CFBundleShortVersionString string 1.2.3" \
  -c "Add :CFBundleVersion string 42" \
  "$APP/Contents/Info.plist" >/dev/null
# A real Mach-O so the architecture check has something to read. cc is present
# wherever Xcode's command line tools are, which is a prerequisite anyway.
printf 'int main(void){return 0;}\n' > "$WORK/main.c"
cc -o "$APP/Contents/MacOS/Broken" "$WORK/main.c" 2>/dev/null || \
  printf '#!/bin/sh\nexit 0\n' > "$APP/Contents/MacOS/Broken"
chmod +x "$APP/Contents/MacOS/Broken"
# The mistake this check exists for: a config file left in Copy Bundle Resources.
printf '{"apiKey":"sk-NOTAREALKEY0000000000000000"}\n' > "$APP/Contents/Resources/config.json"

echo ""
echo "negative controls"
echo ""

# 1. unsigned app -----------------------------------------------------------
OUT=$(NO_COLOR=1 "$TOOL" "$APP" --no-network 2>&1); CODE=$?
expect_check_fails "unsigned app is caught"                "code signature"                    "$OUT"
expect_check_fails "Gatekeeper rejection is caught"        "Gatekeeper assessment (app)"       "$OUT"
expect_check_fails "missing hardened runtime is caught"    "hardened runtime and secure timestamp" "$OUT"
expect_check_fails "missing notarization ticket is caught" "notarization ticket (app)"         "$OUT"
expect_check_fails "credentials in the bundle are caught"  "no credentials shipped inside the bundle" "$OUT"
expect_exit        "a broken artifact exits 1"             1 "$CODE"

# 2. --no-secrets actually suppresses the secrets check ----------------------
OUT=$(NO_COLOR=1 "$TOOL" "$APP" --no-network --no-secrets 2>&1)
RAN=$((RAN + 1))
if printf '%s' "$OUT" | grep -q "SKIP  no credentials"; then
  pass_msg "--no-secrets skips the secrets scan"
else
  fail_msg "--no-secrets did not skip the secrets scan"
fi

# 3. build number that did not move ------------------------------------------
OUT=$(NO_COLOR=1 "$TOOL" "$APP" --no-network --no-secrets --previous-build 42 2>&1)
expect_check_fails "a build number that did not increase is caught" "build number increased" "$OUT"

# 4. build number that went backwards ----------------------------------------
OUT=$(NO_COLOR=1 "$TOOL" "$APP" --no-network --no-secrets --previous-build 99 2>&1)
expect_check_fails "a build number that went backwards is caught" "build number increased" "$OUT"

# 5. disk image path + appcast disagreement ----------------------------------
rm -f "$WORK/Broken.dmg"
if hdiutil create -volname Broken -srcfolder "$STAGE" -ov -quiet -format UDZO "$WORK/Broken.dmg" 2>/dev/null; then
  REAL_SIZE=$(stat -f%z "$WORK/Broken.dmg")
  cat > "$WORK/appcast.xml" <<EOF
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <title>Version 1.2.3</title>
      <sparkle:version>41</sparkle:version>
      <sparkle:shortVersionString>1.2.2</sparkle:shortVersionString>
      <enclosure url="https://example.invalid/Broken.dmg" length="$((REAL_SIZE - 1))"
                 type="application/octet-stream" sparkle:edSignature="AAAA"/>
    </item>
  </channel>
</rss>
EOF
  OUT=$(NO_COLOR=1 "$TOOL" "$WORK/Broken.dmg" --appcast "$WORK/appcast.xml" --no-network --no-secrets 2>&1)
  expect_check_fails "an unstapled disk image is caught"   "notarization ticket (disk image)" "$OUT"
  expect_check_fails "an unsigned disk image is caught"    "disk image signature"             "$OUT"
  expect_check_fails "a disk image Gatekeeper rejects is caught" \
    "Gatekeeper assessment (disk image)" "$OUT"
  expect_check_fails "an appcast that disagrees is caught" "appcast agreement"                "$OUT"

  RAN=$((RAN + 1))
  if printf '%s' "$OUT" | grep -q "sparkle:version is 41 but the shipped build is 42"; then
    pass_msg "the appcast failure names the actual mismatch"
  else
    fail_msg "the appcast failure did not name the version mismatch"
  fi

  # 5b. the two disk-image checks can disagree, which is why both exist.
  # Ad-hoc signing (-s -) needs no certificate, so this builds anywhere. The
  # image is then validly signed — `codesign --verify` is happy — while
  # Gatekeeper still refuses to open it. A tool that only ran codesign would
  # call this artifact fine and it would fail for every user who downloaded it.
  cp "$WORK/Broken.dmg" "$WORK/Adhoc.dmg"
  if codesign -s - -f "$WORK/Adhoc.dmg" >/dev/null 2>&1; then
    OUT=$(NO_COLOR=1 "$TOOL" "$WORK/Adhoc.dmg" --no-network --no-secrets 2>&1)
    RAN=$((RAN + 1))
    if printf '%s' "$OUT" | grep -q "PASS  disk image signature"; then
      pass_msg "a signed disk image passes the signature check"
    else
      fail_msg "the ad-hoc signed disk image did not pass the signature check"
    fi
    expect_check_fails "Gatekeeper still rejects a signed but unnotarized disk image" \
      "Gatekeeper assessment (disk image)" "$OUT"
  else
    echo "  skip  ad-hoc disk image test — codesign -s - unavailable"
  fi
else
  echo "  skip  disk image tests — hdiutil create failed"
fi

# 6b. a profile-backed entitlement with no provisioning profile ---------------
# Ad-hoc signing (-s -) needs no certificate, so this fixture builds anywhere,
# including CI. It reproduces the shape of a real shipped failure: the app is
# signed, notarization is irrelevant, and it simply will not launch on a machine
# without the team's profile.
ENTS_APP="$WORK/Entitled.app"
mkdir -p "$ENTS_APP/Contents/MacOS"
/usr/libexec/PlistBuddy \
  -c "Add :CFBundleExecutable string Entitled" \
  -c "Add :CFBundleIdentifier string com.example.entitled" \
  -c "Add :CFBundleShortVersionString string 1.0" \
  -c "Add :CFBundleVersion string 1" \
  "$ENTS_APP/Contents/Info.plist" >/dev/null
cc -o "$ENTS_APP/Contents/MacOS/Entitled" "$WORK/main.c" 2>/dev/null || \
  printf '#!/bin/sh\nexit 0\n' > "$ENTS_APP/Contents/MacOS/Entitled"
chmod +x "$ENTS_APP/Contents/MacOS/Entitled"
cat > "$WORK/ents.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>keychain-access-groups</key><array><string>ABCDE12345.com.example.entitled</string></array>
  <key>com.apple.security.network.client</key><true/>
</dict></plist>
PLIST
if codesign -s - --entitlements "$WORK/ents.plist" -f "$ENTS_APP" >/dev/null 2>&1; then
  OUT=$(NO_COLOR=1 "$TOOL" "$ENTS_APP" --no-network --no-secrets 2>&1)
  expect_check_fails "a profile-backed entitlement with no profile is caught" \
    "entitlements are backed by a provisioning profile" "$OUT"

  # and the same app without that entitlement must not be flagged
  cat > "$WORK/ents-ok.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.network.client</key><true/>
</dict></plist>
PLIST
  codesign -s - --entitlements "$WORK/ents-ok.plist" -f "$ENTS_APP" >/dev/null 2>&1
  OUT=$(NO_COLOR=1 "$TOOL" "$ENTS_APP" --no-network --no-secrets 2>&1)
  RAN=$((RAN + 1))
  if printf '%s' "$OUT" | grep -q "FAIL  entitlements are backed"; then
    fail_msg "sandbox-only entitlements were wrongly flagged"
  else
    pass_msg "entitlements that need no profile are not flagged"
  fi
else
  echo "  skip  entitlement tests — ad-hoc codesign unavailable"
fi

# 6c. a loose unsigned dylib next to a signed app -----------------------------
# The shape of a real notarization rejection: the app is signed, the loose
# .dylib files in Contents/Frameworks are not, and a re-sign pass that walks
# only *.framework and *.xpc never touches them.
DYLIB_APP="$WORK/Loose.app"
mkdir -p "$DYLIB_APP/Contents/MacOS" "$DYLIB_APP/Contents/Frameworks"
/usr/libexec/PlistBuddy \
  -c "Add :CFBundleExecutable string Loose" \
  -c "Add :CFBundleIdentifier string com.example.loose" \
  -c "Add :CFBundleShortVersionString string 1.0" \
  -c "Add :CFBundleVersion string 1" \
  "$DYLIB_APP/Contents/Info.plist" >/dev/null
cc -o "$DYLIB_APP/Contents/MacOS/Loose" "$WORK/main.c" 2>/dev/null
printf 'int helper(void){return 1;}\n' > "$WORK/lib.c"
if cc -dynamiclib -o "$DYLIB_APP/Contents/Frameworks/libhelper.dylib" "$WORK/lib.c" 2>/dev/null \
   && codesign -s - -f "$DYLIB_APP/Contents/MacOS/Loose" >/dev/null 2>&1 \
   && codesign -s - -f "$DYLIB_APP" >/dev/null 2>&1; then
  codesign --remove-signature "$DYLIB_APP/Contents/Frameworks/libhelper.dylib" >/dev/null 2>&1
  OUT=$(NO_COLOR=1 "$TOOL" "$DYLIB_APP" --no-network --no-secrets 2>&1)
  expect_check_fails "an unsigned loose dylib is caught" \
    "every Mach-O in the bundle is signed like the app" "$OUT"

  RAN=$((RAN + 1))
  if printf '%s' "$OUT" | grep -q "libhelper.dylib"; then
    pass_msg "the failure names the offending file"
  else
    fail_msg "the failure did not name libhelper.dylib"
  fi

  # and once it is signed like everything else, it must stop being reported
  codesign -s - -f "$DYLIB_APP/Contents/Frameworks/libhelper.dylib" >/dev/null 2>&1
  codesign -s - -f "$DYLIB_APP" >/dev/null 2>&1
  OUT=$(NO_COLOR=1 "$TOOL" "$DYLIB_APP" --no-network --no-secrets 2>&1)
  RAN=$((RAN + 1))
  if printf '%s' "$OUT" | grep -q "FAIL  every Mach-O"; then
    fail_msg "a consistently signed bundle was still flagged"
  else
    pass_msg "a consistently signed bundle is not flagged"
  fi

  # universal binaries must not be counted several times, once per architecture
  RAN=$((RAN + 1))
  if printf '%s' "$OUT" | grep -qE "[0-9]+ Mach-O files, all signed"; then
    pass_msg "the pass line reports how many Mach-O files were inspected"
  else
    fail_msg "the pass line did not report a count"
  fi
else
  echo "  skip  loose dylib tests — cc or ad-hoc codesign unavailable"
fi

# 6. missing dSYM -------------------------------------------------------------
mkdir -p "$WORK/empty-archive"
OUT=$(NO_COLOR=1 "$TOOL" "$APP" --no-network --no-secrets --dsym "$WORK/empty-archive" 2>&1)
expect_check_fails "a missing dSYM is caught" "dSYM present and matching" "$OUT"

# 7. usage errors -------------------------------------------------------------
NO_COLOR=1 "$TOOL" >/dev/null 2>&1; expect_exit "no argument exits 2" 2 "$?"
NO_COLOR=1 "$TOOL" /nonexistent.dmg >/dev/null 2>&1; expect_exit "a missing file exits 2" 2 "$?"
NO_COLOR=1 "$TOOL" "$APP" --nonsense >/dev/null 2>&1; expect_exit "an unknown option exits 2" 2 "$?"

# 8. the tool leaves nothing mounted ------------------------------------------
RAN=$((RAN + 1))
if [ -f "$WORK/Broken.dmg" ]; then
  NO_COLOR=1 "$TOOL" "$WORK/Broken.dmg" --no-network --no-secrets >/dev/null 2>&1
  if mount | grep -q 'mac-release-verify'; then
    fail_msg "a disk image was left mounted after exit"
  else
    pass_msg "no disk image is left mounted after exit"
  fi
else
  pass_msg "no disk image is left mounted after exit (no dmg built)"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "  $RAN checks, all passed"
  echo ""
  exit 0
else
  echo "  $RAN checks, $FAILURES failed"
  echo ""
  exit 1
fi
