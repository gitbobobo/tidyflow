# Codesign Verification Checklist

## Pre-flight

- [ ] Certificate installed: `security find-identity -v -p codesigning`
- [ ] Identity string copied exactly (including TEAMID)

## Build

- [ ] Run: `SIGN_IDENTITY="..." ./scripts/release/build_dmg.sh --sign`
- [ ] Script outputs "Signing complete" without errors
- [ ] DMG created in `dist/TidyFlow-*.dmg`

## Verify Signature

- [ ] Mount DMG and run:
  ```bash
  codesign --verify --deep --strict --verbose=2 /Volumes/TidyFlow/TidyFlow.app
  ```
- [ ] Output shows: `valid on disk` and `satisfies its Designated Requirement`

## Gatekeeper (Expected to Warn)

- [ ] Run: `spctl --assess --type execute --verbose /Volumes/TidyFlow/TidyFlow.app`
- [ ] Expected: "rejected" or "not notarized" (normal until D5-3)

## Runtime Test

- [ ] Copy to /Applications
- [ ] Launch app - may show Gatekeeper warning (expected)
- [ ] App runs, Core process starts, UI functional
