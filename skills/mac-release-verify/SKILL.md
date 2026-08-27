---
name: mac-release-verify
description: Verify a macOS release artifact (.app, .dmg or .xcarchive) before publishing it — code signature, Gatekeeper, notarization tickets on both the app and the disk image, Sparkle appcast agreement, build-number monotonicity, dSYM UUID match, and credentials left in the bundle. Use whenever a Mac app is about to be shipped, notarized, published to a Sparkle feed, or uploaded to App Store Connect, or when a user reports "the download will not open" or "the update is not being offered".
---

# Verifying a macOS release

The mistakes this catches do not fail a build. The archive succeeds, the upload
goes through, CI stays green, and the damage shows up later — a download nobody
can open, an update nobody is offered, a crash report nobody can read.

## Run it

```sh
mac-release-verify <artifact> [--appcast <path|url>] [--dsym <path>] [--previous-build <n>]
```

Use every flag you have the information for. Each one unlocks checks that are
skipped otherwise:

- `--appcast` — cross-checks `sparkle:version`, `shortVersionString`, the
  enclosure `length` against the real byte size, and that an `edSignature` exists
- `--dsym` — accepts a `.dSYM`, a directory, or an `.xcarchive`; matches UUIDs
  against the shipped binary
- `--previous-build` — the `CFBundleVersion` of the last release you shipped

Exit code is 0 when everything passed and 1 when something failed, so it can gate
a release script directly.

## Reading the result

Every failure states the consequence, not just the rule. Do not paraphrase it
into "a check failed" — the consequence is the reason to act.

## When something fails

Fix and re-run. Do not staple, re-sign or re-notarize on the user's behalf
without saying what you are about to do: those operations mutate the artifact
they are about to ship.

Two failures are worth calling out explicitly because they are silent in
production:

- **notarization ticket (disk image)** — the app is stapled but the DMG is not.
  Gatekeeper inspects the DMG at download time, so every download is blocked
  even though the app inside is fine.
- **build number increased** — Sparkle compares `CFBundleVersion`, not the
  marketing version. If it did not move, existing users are told they are
  already up to date and the update never installs.

## What it will not do

It only reads. It never signs, notarizes, uploads, publishes, tags or modifies
anything, and it never asks for credentials. If a task needs one of those, that
is a separate step the user has to approve.
