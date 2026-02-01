# D5-2: Developer ID Application Signing

## Overview

This phase adds optional code signing to the DMG build process using a Developer ID Application certificate. Signed apps can be distributed outside the Mac App Store while satisfying Gatekeeper requirements (after notarization in D5-3).

## Prerequisites

1. **Apple Developer Program membership** ($99/year)
2. **Developer ID Application certificate** installed in Keychain
   - Created via Xcode > Settings > Accounts > Manage Certificates
   - Or via Apple Developer Portal > Certificates
3. **Keychain Access** - certificate must be in login or System keychain

### Verify Certificate Availability

```bash
security find-identity -v -p codesigning
```

Look for: `Developer ID Application: Your Name (TEAMID)`

## Usage

### Unsigned Build (default, D5-1 behavior)

```bash
./scripts/release/build_dmg.sh
```

### Signed Build

```bash
# Using environment variable
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/release/build_dmg.sh --sign

# Using --identity argument
./scripts/release/build_dmg.sh --sign --identity "Developer ID Application: Your Name (TEAMID)"
```

## Signing Process

### Order of Operations

1. **Build app** via xcodebuild (Release configuration)
2. **Sign embedded core** (`TidyFlow.app/Contents/Resources/Core/tidyflow-core`)
   - No entitlements (standalone binary)
   - `--options runtime` for hardened runtime
   - `--timestamp` for secure timestamp
3. **Sign main app bundle** (`TidyFlow.app`)
   - With entitlements (`app/TidyFlow/TidyFlow.entitlements`)
   - `--deep` to catch any nested items
   - `--options runtime` for hardened runtime
4. **Verify signature** via `codesign --verify`
5. **Gatekeeper check** via `spctl --assess` (may fail until notarized)
6. **Create DMG** with signed app

### Entitlements

Current entitlements (`app/TidyFlow/TidyFlow.entitlements`):

| Key | Value | Purpose |
|-----|-------|---------|
| `com.apple.security.app-sandbox` | false | Disabled for Core process management |
| `com.apple.security.network.client` | true | HTTP client for Core API |

## Verification Commands

```bash
# Verify signature integrity
codesign --verify --deep --strict --verbose=2 /path/to/TidyFlow.app

# Check Gatekeeper assessment (may fail until notarized)
spctl --assess --type execute --verbose /path/to/TidyFlow.app

# Display signature details
codesign -dv --verbose=4 /path/to/TidyFlow.app

# Check entitlements
codesign -d --entitlements - /path/to/TidyFlow.app
```

## Common Errors

### 1. Identity Not Found

```
ERROR: --sign requires SIGN_IDENTITY env or --identity argument
```

**Solution:** Run `security find-identity -v -p codesigning` and use exact identity string.

### 2. Entitlements Mismatch

```
errSecInternalComponent / The signature is invalid
```

**Solution:** Ensure entitlements file exists and is valid XML plist.

### 3. Hardened Runtime Issues

```
code signature not valid for use in process
```

**Solution:** Ensure `--options runtime` is used for all binaries.

### 4. Timestamp Server Unavailable

```
timestamp service is not available
```

**Solution:** Check network connectivity; Apple's timestamp server may be temporarily down.

## Limitations (D5-2)

1. **Not notarized** - Gatekeeper will still warn on first run
2. **No stapling** - Notarization ticket not attached to DMG
3. **Manual identity** - Must specify identity each build

## Next Steps (D5-3)

1. Add `xcrun notarytool submit` for notarization
2. Add `xcrun stapler staple` for ticket attachment
3. Automate identity detection from Keychain
4. CI/CD integration with stored credentials
