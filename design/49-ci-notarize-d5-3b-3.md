# D5-3b-3: CI Notarization

## Overview

Adds notarization support to the GitHub Actions workflow for DMG builds. When enabled, the signed DMG is submitted to Apple's notary service, stapled with the notarization ticket, and verified to pass Gatekeeper assessment.

## GitHub Secrets Required

| Secret | Description | Example |
|--------|-------------|---------|
| `ASC_API_KEY_ID` | App Store Connect API Key ID | `ABCDE12345` |
| `ASC_API_ISSUER_ID` | App Store Connect Issuer ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `ASC_API_KEY_P8_BASE64` | AuthKey_XXXX.p8 content (base64) | `base64 -i AuthKey_XXXX.p8` |

## Workflow Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `skip_core` | boolean | false | Skip core rebuild |
| `sign` | boolean | false | Sign with Developer ID |
| `notarize` | boolean | false | Notarize (requires sign=true) |

## Input Combinations

| sign | notarize | Result |
|------|----------|--------|
| false | false | Unsigned DMG |
| true | false | Signed DMG (Gatekeeper warning) |
| false | true | **FAIL** - notarize requires sign |
| true | true | Signed + Notarized DMG (Gatekeeper accepted) |

## Notarization Flow

```
1. Build DMG (existing)
2. Sign app (existing, if sign=true)
3. Verify signature
4. Setup API key (decode from secret)
5. Submit to notary service (notarytool submit --wait)
6. Staple ticket (stapler staple)
7. Validate staple (stapler validate)
8. Verify Gatekeeper (spctl --assess → accepted)
9. Cleanup API key
10. Upload artifact (DMG + notarytool logs)
```

## Commands Used

### Submit for Notarization
```bash
xcrun notarytool submit "$DMG" \
  --key AuthKey.p8 \
  --key-id "$ASC_API_KEY_ID" \
  --issuer "$ASC_API_ISSUER_ID" \
  --wait \
  --output-format json > dist/notarytool-submit.json
```

### Staple Ticket
```bash
xcrun stapler staple "$DMG"
```

### Validate Staple
```bash
xcrun stapler validate "$DMG"
```

### Verify Gatekeeper
```bash
spctl --assess --type execute --verbose "/Volumes/TidyFlow/TidyFlow.app"
# Expected output: accepted source=Notarized Developer ID
```

## Artifact Naming

| Condition | Artifact Name Pattern |
|-----------|----------------------|
| Unsigned | `TidyFlow-{version}-{sha}` |
| Signed | `TidyFlow-{version}-signed-{sha}` |
| Notarized | `TidyFlow-{version}-notarized-{sha}` |

Artifact includes:
- `TidyFlow-{version}.dmg`
- `notarytool-submit.json` (submission result)
- `notarytool-log.json` (detailed log, if failure)

## Common Failures

### 1. Invalid API Key
```
Error: Unable to authenticate
```
**Fix:** Verify ASC_API_KEY_ID, ASC_API_ISSUER_ID, and ASC_API_KEY_P8_BASE64 are correct.

### 2. App Not Signed
```
Error: Notarization requires signing
```
**Fix:** Enable `sign=true` when using `notarize=true`.

### 3. Hardened Runtime Missing
```
Error: The signature does not include a secure timestamp
```
**Fix:** Ensure build_dmg.sh uses `--options runtime` in codesign.

### 4. Unsigned Nested Code
```
Error: The binary is not signed with a valid Developer ID certificate
```
**Fix:** Ensure all binaries (including Core) are signed.

### 5. Notarization Timeout
```
Error: Submission timed out
```
**Fix:** Apple's service may be slow. Retry or check status manually.

## Troubleshooting

### Check Submission Status
```bash
xcrun notarytool history --key AuthKey.p8 --key-id $KEY_ID --issuer $ISSUER_ID
```

### Get Detailed Log
```bash
xcrun notarytool log $SUBMISSION_ID --key AuthKey.p8 --key-id $KEY_ID --issuer $ISSUER_ID
```

### Verify Locally
```bash
# Mount DMG
hdiutil attach TidyFlow-*.dmg

# Check Gatekeeper
spctl --assess --type execute -v /Volumes/TidyFlow/TidyFlow.app

# Check notarization status
xcrun stapler validate TidyFlow-*.dmg
```

## Security Notes

1. API key file is created temporarily and deleted after use
2. Key file permissions set to 600 (owner read/write only)
3. Secrets never logged to workflow output
4. Keychain is deleted after workflow completes

## References

- [Apple: Notarizing macOS Software](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
- [notarytool man page](https://keith.github.io/xcode-man-pages/notarytool.1.html)
- [App Store Connect API Keys](https://developer.apple.com/documentation/appstoreconnectapi/creating_api_keys_for_app_store_connect_api)
