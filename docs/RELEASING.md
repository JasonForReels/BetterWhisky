# Releasing BetterWhisky

One command builds, signs, notarizes, publishes and updates the in-app updater feed:

```sh
scripts/release.sh 1.0.0
```

It archives the app with the version you give and a fresh build number, signs it with
**Developer ID Application: Jason Smith (MZT889Z6FM)**, packages and notarizes a DMG, signs the
DMG for the in-app updater, adds it to [`appcast.xml`](../appcast.xml), creates the GitHub release
`v1.0.0` on JasonForReels/BetterWhisky with the DMG attached, and pushes the updated feed.
Installed copies of BetterWhisky see the update the next time they check.

Add `--no-publish` to build and update `appcast.xml` locally without releasing.

## One-time setup

| Needed | State |
| --- | --- |
| Developer ID Application certificate (team MZT889Z6FM) | In the login keychain |
| Updater signing key, account `BetterWhisky` | In the login keychain; public half in `Whisky/Info.plist` (`SUPublicEDKey`) |
| Update feed | `appcast.xml` in this repository, read from `raw.githubusercontent.com` (`SUFeedURL`) |
| Notary credentials, profile `BetterWhisky` | **To do**, see below |
| `gh` signed in as JasonForReels | Done |

### Notary credentials

Create an app-specific password at [appleid.apple.com](https://appleid.apple.com) (Sign-In and
Security → App-Specific Passwords), then store it once:

```sh
xcrun notarytool store-credentials BetterWhisky --apple-id <your Apple ID> --team-id MZT889Z6FM
```

### Back up the updater signing key

The private half of the updater key exists only in this Mac's login keychain. If it's lost, no
future update can be signed for apps people already have. Export a copy to somewhere safe and
private (a password manager or an encrypted drive, never this repository):

```sh
"$(find ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin' -type d | head -1)/generate_keys" \
    --account BetterWhisky -x ~/Desktop/BetterWhisky-sparkle-key.txt
```

To use it on another Mac, import it with `generate_keys --account BetterWhisky -f <file>`.
