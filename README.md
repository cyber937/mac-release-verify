# mac-release-verify

**Check a macOS release before you ship it. Read-only, no credentials, no network required.**

<sub>Part of [Sail Manifest](https://sailmanifest.app) — tools for getting a Mac app out the door exactly once.</sub>

```
$ mac-release-verify MyApp-2.1.1.dmg --appcast appcast.xml --dsym MyApp.xcarchive --previous-build 200

  target   MyApp-2.1.1.dmg
  app      MyApp.app  2.1.1 (201)

  PASS  code signature
  PASS  Gatekeeper assessment (app)
  PASS  notarization ticket (app)
  FAIL  notarization ticket (disk image)
        The app is stapled but the disk image is not. Gatekeeper checks the
        disk image when the user opens the download, so this blocks every
        download even though the app inside is fine.
        fix: xcrun stapler staple "MyApp-2.1.1.dmg"
  ...
```

## Why this exists

None of the mistakes below make a build fail. The compiler is happy, the archive
succeeds, the upload goes through, CI stays green. You find out from a user, or
from a crash you cannot read, or from an update that never arrives.

Some of the checks here are the obvious ones — a valid signature, a stapled
ticket. These are the ones that exist because a release went out broken and
nothing failed:

| What shipped | What the user got |
|---|---|
| The `.app` was notarized, then wrapped in a DMG. The **DMG** was never notarized | Gatekeeper inspects the disk image at download time. Nobody could open it |
| `MARKETING_VERSION` was bumped, `CURRENT_PROJECT_VERSION` was not | Sparkle compares the **build** number. Every existing user was told they were already up to date |
| The appcast was generated from build settings instead of from the built DMG | The feed advertised a version that did not match the binary behind it |
| The dSYM was not kept | Every crash report from that version arrived as raw addresses, for the whole life of the release. A dSYM cannot be produced after the fact |
| A config file stayed in Copy Bundle Resources | The key was inside every copy downloaded, and a released build cannot be recalled |
| Loose `.dylib` files in `Contents/Frameworks` kept the Apple Development signature from the Xcode archive | Each was validly signed, so `--deep --strict` passed. Apple's notary service rejected the whole submission, once per file, after the upload |
| An entitlement that only a provisioning profile can grant, in a build carrying no profile | The app refused to launch. No security prompt, no crash report, reinstalling changed nothing — and it opened normally on the machine that built it |
| A DMG that was signed and looked fine to `codesign`, but was never notarized | Gatekeeper refused to open the download. The signature check and the ticket check had both been read as "probably fine"; only asking Gatekeeper gave the answer the user got |

## Install

```sh
brew install cyber937/tap/mac-release-verify     # (coming with v0.1.0)
```

or just drop the script somewhere on your `PATH` — it is a single file:

```sh
curl -fsSL https://raw.githubusercontent.com/cyber937/mac-release-verify/main/bin/mac-release-verify \
  -o /usr/local/bin/mac-release-verify && chmod +x /usr/local/bin/mac-release-verify
```

No runtime to install. It uses only tools that ship with macOS (`codesign`,
`spctl`, `stapler`, `hdiutil`, `PlistBuddy`, `dwarfdump`, `lipo`, `xmllint`,
`curl`) and targets bash 3.2, the `/bin/bash` a stock Mac has.

## Usage

```
mac-release-verify <app-or-dmg-or-xcarchive> [options]

  --appcast <path|url>    Cross-check a Sparkle appcast against the artifact
  --dsym <path>           .dSYM bundle, or a directory/.xcarchive containing one
  --previous-build <n>    Assert the build number increased since this one
  --no-network            Skip every check that touches the network
  --no-secrets            Skip the bundled-secrets scan
  --format text|github    github emits GitHub Actions annotations
  --quiet                 Only print failures and the summary
```

Exit code is `0` when everything passed, `1` when something failed, `2` on a
usage error — so it drops straight into a release script:

```sh
./mac-release-verify "build/MyApp-$VERSION.dmg" \
  --appcast build/appcast.xml \
  --dsym build/MyApp.xcarchive \
  --previous-build "$LAST_SHIPPED_BUILD" || exit 1
```

## It knows how you are shipping

An App Store build is signed with an Apple Distribution certificate and is
re-signed by Apple after upload, so it legitimately has no Developer ID
notarization ticket, no secure timestamp, and is rejected by `spctl`. Reporting
those as failures would mean reporting a correct artifact as broken, so the
checks that only apply to direct distribution are skipped and the reason is
printed.

The reverse is a real failure and is reported as one: an App Store build found
inside a disk image cannot run for anyone who downloads it.

## What it checks

1. Code signature valid (`--deep --strict`)
2. Gatekeeper accepts the app
3. Hardened runtime **and** secure timestamp present
4. Entitlements that need a provisioning profile are backed by one
5. Notarization ticket stapled to the **app**
6. Notarization ticket stapled to the **disk image**
7. Gatekeeper accepts the **disk image** — the decision the user's Mac makes at download time
8. Disk image itself is signed
9. `CFBundleShortVersionString` / `CFBundleVersion` present and numerically orderable
10. Build number actually increased since the last release
11. Appcast agrees with the artifact — `sparkle:version`, `shortVersionString`, enclosure `length` vs real byte size, `edSignature` present
12. `SUPublicEDKey` present, so Sparkle can verify signatures at all
13. Appcast download URL returns 200
14. dSYM exists and its UUIDs match the shipped binary
15. Architectures and `LSMinimumSystemVersion`
16. Embedded frameworks / XPC services / extensions are validly signed
17. No credential-shaped files inside the bundle

### Asking Gatekeeper about a disk image

Checks 6 and 7 are not the same question and they can disagree. `stapler
validate` asks whether a ticket is attached to the file; Gatekeeper asks whether
it will let the download open. When they disagree, the second answer is the one
your users get — an unnotarized disk image that had passed the other two checks
is what this check was added for.

The form of the question matters:

```sh
spctl --assess --type open --context context:primary-signature -v MyApp.dmg   # this one
spctl --assess --type execute -v MyApp.dmg                                    # not this one
```

A disk image is not executable code, so `--type execute` answers `rejected (the
code is valid but does not seem to be an app)` for **every** disk image,
including a correctly notarized one. Verifying by hand with that form is the
usual way to conclude, wrongly, that notarizing the image did not work. The tool
prints which form it used.

## What it does not do

It does not sign, notarize, upload, publish, tag, or modify anything. It mounts
disk images read-only and unmounts them when it exits. It never asks for your
Apple ID, an App Store Connect key, or any other credential.

That is deliberate: you should be able to run an unfamiliar tool against your
signed release without thinking about what it might touch.

## Tests

```sh
./tests/negative-controls.sh
```

A checker that only ever reports PASS is indistinguishable from one that does
nothing. Every check is therefore exercised against a deliberately broken
artifact built on the fly — unsigned app, unstapled disk image, an appcast that
disagrees with the binary, a build number that did not move, a missing dSYM, a
credential left in Resources, a signed disk image that Gatekeeper still refuses.
No signing identity, Apple account or network needed. 23 assertions, and they run
on `macos-latest` in CI under the same bash 3.2 the tool targets.

## Use it from an AI agent

`skills/mac-release-verify/` is a Claude Agent Skill. Point your agent at it and
it will know when to run this, which flags actually matter, and — importantly —
that it must not sign, staple or upload anything on your behalf.

## Contributing

The useful contribution is **a failure mode that actually shipped for you**.
There is [a template for it](https://github.com/cyber937/mac-release-verify/issues/new?template=failure-report.yml),
and it asks three things: what shipped, what the user saw, and what could have
been read from the artifact instead.

It does not ask for steps to reproduce. If it reproduced on your machine you
would have caught it before shipping — that is the whole shape of these bugs.

Reports that the tool **failed an artifact that was fine** are just as valuable.
A checker that fails correct builds teaches people to ignore it.

## License

MIT — see [LICENSE](LICENSE).

"Sail Manifest"™ is a trademark of Cyberseeds. The MIT license covers the code,
not the name or the branding.

## Not a guarantee

Several of these checks exist because a release shipped broken. They are **not a
complete list of everything that can go wrong with a macOS release**, and a clean run does
not mean the release is correct — only that these particular mistakes are absent.
Know of one that is missing? See *Contributing*.

---

## 日本語

**出す前に、出すものを検査する。読むだけ・資格情報不要・ネットワーク不要。**

ここに入っている検査は、すべて**実際に出荷して事故になったもの**です。どれも
ビルドは通ります。CI も緑のままです。気づくのは、ユーザーからの連絡か、読めない
クラッシュレポートか、いつまでも降ってこない更新によってです。

- `.app` だけ公証して DMG を公証し忘れる → Gatekeeper は**ダウンロードを開く時点で DMG を見る**ので、誰も開けない
- `MARKETING_VERSION` は上げたが `CURRENT_PROJECT_VERSION` を上げ忘れる → Sparkle が見るのは**ビルド番号**なので、全ユーザーに「最新です」と表示される
- appcast をビルド設定から生成する → 実際に置いた DMG と違う版を配信してしまう
- dSYM を保存し忘れる → その版のクラッシュが**公開期間中ずっと**読めない。dSYM は後から作れない
- 設定ファイルがバンドルに残る → 配った全コピーに鍵が入る。出荷済みビルドは回収できない

署名・公証・アップロード・公開・タグ付けは**一切しません**。ディスクイメージは
読み取り専用でマウントし、終了時に必ずアンマウントします。Apple ID も App Store
Connect のキーも要求しません。
