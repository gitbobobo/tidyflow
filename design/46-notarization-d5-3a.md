# D5-3a: macOS Notarization

## Overview

Apple notarization is required for apps distributed outside the Mac App Store. Without notarization, users see Gatekeeper warnings and must manually bypass security.

## Prerequisites

1. **Signed DMG**: Run `build_dmg.sh --sign` first (D5-2)
2. **Apple Developer Account**: Enrolled in Apple Developer Program
3. **Xcode Command Line Tools**: `xcode-select --install`
4. **App-Specific Password**: Generated at appleid.apple.com

## Keychain Profile Setup (One-Time)

Create a keychain profile to store credentials securely:

```bash
xcrun notarytool store-credentials tidyflow-notary \
  --apple-id your@email.com \
  --team-id YOURTEAMID \
  --password <app-specific-password>
```

Where:
- `tidyflow-notary`: Profile name (can be any name)
- `--apple-id`: Your Apple Developer email
- `--team-id`: 10-character Team ID (find at developer.apple.com/account)
- `--password`: App-specific password from appleid.apple.com > Security

The credentials are stored in macOS Keychain, not in plaintext.

## Notarization Flow

```
build_dmg.sh --sign
       │
       ▼
   Signed DMG
       │
       ▼
notarize.sh --profile tidyflow-notary
       │
       ├─► notarytool submit --wait
       │         │
       │         ▼
       │   Apple scans binary
       │         │
       │         ▼
       ├─► stapler staple (attach ticket)
       │
       ▼
  Notarized DMG (distribution ready)
```

## Usage

```bash
# Basic usage (finds latest DMG in dist/)
./scripts/release/notarize.sh --profile tidyflow-notary

# Specify DMG explicitly
./scripts/release/notarize.sh --profile tidyflow-notary --dmg dist/TidyFlow-1.0.0-1.dmg
```

## Verification

After notarization:

```bash
# Validate staple on DMG
xcrun stapler validate dist/TidyFlow-*.dmg

# Mount and check app
hdiutil attach dist/TidyFlow-*.dmg
spctl --assess --type execute --verbose /Volumes/TidyFlow/TidyFlow.app
hdiutil detach /Volumes/TidyFlow
```

Expected output for spctl:
```
/Volumes/TidyFlow/TidyFlow.app: accepted
source=Notarized Developer ID
```

## Common Errors

### 1. "The signature of the binary is invalid"

**Cause**: App not signed or signed incorrectly.

**Fix**: Ensure `build_dmg.sh --sign` completed successfully:
```bash
codesign --verify --deep --strict --verbose=2 dist/dmgroot/TidyFlow.app
```

### 2. "The executable does not have the hardened runtime enabled"

**Cause**: Missing `--options runtime` during signing.

**Fix**: Already handled in `build_dmg.sh`. If persists, check:
```bash
codesign -dvv TidyFlow.app | grep flags
# Should show: flags=0x10000(runtime)
```

### 3. "The signature does not include a secure timestamp"

**Cause**: Missing `--timestamp` during signing.

**Fix**: Already handled in `build_dmg.sh`. Requires internet during signing.

### 4. "The bundle identifier is missing or invalid"

**Cause**: Info.plist missing CFBundleIdentifier.

**Fix**: Verify in Xcode project settings.

### 5. "Package Invalid" or submission rejected

**Cause**: Various issues with binary content.

**Fix**: Check the notarization log:
```bash
xcrun notarytool log <submission-id> --keychain-profile tidyflow-notary log.json
cat log.json | jq '.issues'
```

### 6. Profile not found

**Cause**: Keychain profile not created or wrong name.

**Fix**: List profiles:
```bash
xcrun notarytool store-credentials --help
# Re-create profile if needed
```

## Notarization Timeline

- **Submission**: Instant
- **Processing**: 2-15 minutes (typically 5 minutes)
- **Stapling**: Instant

First submission may take longer. Subsequent submissions are faster.

## Security Notes

1. **App-Specific Password**: Never commit to git. Generate at appleid.apple.com.
2. **Keychain Profile**: Stored in macOS Keychain, encrypted.
3. **Team ID**: Public information, safe to share.

## Files

| File | Purpose |
|------|---------|
| `scripts/release/notarize.sh` | Notarization script |
| `scripts/release/build_dmg.sh` | Build + sign (prerequisite) |
| `dist/TidyFlow-*.dmg` | Output (notarized) |
| `dist/notarization-log-*.json` | Error log (if failed) |

## Next Steps

- **D5-3b**: GitHub Actions CI/CD for automated notarization
- **D5-4**: Sparkle auto-update integration
