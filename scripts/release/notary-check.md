# Notarization Checklist

## Prerequisites
- [ ] Apple Developer account enrolled
- [ ] App-specific password generated (appleid.apple.com)
- [ ] Keychain profile created: `xcrun notarytool store-credentials tidyflow-notary ...`

## Build & Sign
- [ ] `SIGN_IDENTITY=... ./scripts/release/build_dmg.sh --sign` succeeds
- [ ] `codesign --verify dist/dmgroot/TidyFlow.app` passes (before DMG)

## Notarize
- [ ] `./scripts/release/notarize.sh --profile tidyflow-notary` succeeds
- [ ] Status shows "Accepted"

## Verify
- [ ] `xcrun stapler validate dist/TidyFlow-*.dmg` passes
- [ ] Mount DMG: `hdiutil attach dist/TidyFlow-*.dmg`
- [ ] `spctl --assess --type execute --verbose /Volumes/TidyFlow/TidyFlow.app` shows "accepted"
- [ ] Detach: `hdiutil detach /Volumes/TidyFlow`

## User Test
- [ ] Download DMG on clean Mac (or delete quarantine: `xattr -d com.apple.quarantine ...`)
- [ ] Double-click opens without Gatekeeper warning
