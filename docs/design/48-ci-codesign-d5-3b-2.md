# D5-3b-2: CI Code Signing for DMG Distribution

## Overview

This document describes the GitHub Actions workflow for building signed DMG packages using Developer ID Application certificates.

## Required GitHub Secrets

| Secret Name | Description | How to Obtain |
|-------------|-------------|---------------|
| `MACOS_CERT_P12_BASE64` | Developer ID Application certificate (p12 format, base64 encoded) | Export from Keychain Access, then `base64 -i cert.p12` |
| `MACOS_CERT_PASSWORD` | Password used when exporting the p12 file | Set during p12 export |
| `SIGN_IDENTITY` | Full signing identity string | `security find-identity -v -p codesigning` |

### Example SIGN_IDENTITY Format
```
Developer ID Application: Your Name (TEAMID)
```

## Keychain Flow in CI

```
1. Create temporary keychain (build.keychain)
   └─ Password: unique per run (run_id + run_attempt)

2. Configure keychain
   └─ Timeout: 6 hours (21600 seconds)
   └─ Unlock for codesign access

3. Import certificate
   └─ Decode base64 to temp file
   └─ Import to build.keychain
   └─ Delete temp file immediately

4. Set partition list
   └─ Allow apple-tool: and apple: access
   └─ Prevents "User interaction is not allowed" error

5. Build and sign
   └─ SIGN_IDENTITY env var passed to build_dmg.sh
   └─ build_dmg.sh --sign handles actual codesign calls

6. Cleanup (always runs)
   └─ Delete build.keychain
```

## Workflow Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `skip_core` | boolean | false | Skip Rust core rebuild (use cached) |
| `sign` | boolean | false | Sign the app with Developer ID certificate |

## Verification Steps

When `sign=true`, the workflow performs:

1. **codesign --verify**: Validates signature integrity
   - Must pass for job to succeed
   - Checks deep (all nested code)
   - Strict mode enabled

2. **spctl --assess**: Gatekeeper assessment
   - Expected to fail (not notarized)
   - Does not fail the job
   - Logs warning about notarization

## Artifact Naming

| Condition | Artifact Name Pattern |
|-----------|----------------------|
| `sign=false` | `TidyFlow-{version}-{sha}` |
| `sign=true` | `TidyFlow-{version}-signed-{sha}` |

## Security Considerations

1. **No secrets in logs**: Certificate content and passwords never printed
2. **Temp file cleanup**: p12 decoded to temp file, deleted immediately after import
3. **Keychain isolation**: Unique keychain per run, deleted after job
4. **Keychain password**: Derived from run ID (unique, not sensitive)

## Common Errors

### "User interaction is not allowed"
**Cause**: Keychain not properly configured for non-interactive access
**Fix**: Ensure `security set-key-partition-list` runs after import

### "No identity found"
**Cause**: Certificate not imported or wrong identity string
**Fix**:
1. Verify p12 contains private key (not just certificate)
2. Check SIGN_IDENTITY matches exactly (including Team ID)

### "errSecInternalComponent"
**Cause**: Keychain locked or partition list not set
**Fix**: Ensure unlock and partition-list steps complete before signing

### "The signature is invalid"
**Cause**: Certificate expired or revoked
**Fix**: Export fresh certificate from Apple Developer portal

## Limitations (D5-3b-2)

1. **Not notarized**: Gatekeeper will warn on first run
2. **Manual trigger only**: No automatic release workflow yet
3. **No stapling**: Notarization ticket not attached to DMG

## Next Steps

- **D5-3b-3**: Add notarization using App Store Connect API key
- **D5-3c**: Automatic GitHub Release on tag push
