# CI Code Signing Checklist

## Configure GitHub Secrets

1. Go to repo Settings > Secrets and variables > Actions
2. Add these repository secrets:
   - `MACOS_CERT_P12_BASE64` - base64 encoded p12 certificate
   - `MACOS_CERT_PASSWORD` - p12 export password
   - `SIGN_IDENTITY` - e.g. "Developer ID Application: Name (TEAMID)"

## Export Certificate (Local)

```bash
# Find your identity
security find-identity -v -p codesigning

# Export from Keychain Access:
# 1. Open Keychain Access
# 2. Find "Developer ID Application" certificate
# 3. Right-click > Export (include private key)
# 4. Save as .p12, set password

# Encode for GitHub
base64 -i YourCert.p12 | pbcopy
# Paste into MACOS_CERT_P12_BASE64 secret
```

## Trigger Signed Build

1. Go to Actions > "Build Release DMG"
2. Click "Run workflow"
3. Check "Sign the app with Developer ID certificate"
4. Click "Run workflow"

## Verify Artifact

1. Download artifact from workflow run
2. Mount DMG: `hdiutil attach TidyFlow-*.dmg`
3. Verify signature:
   ```bash
   codesign --verify --deep --strict -v /Volumes/TidyFlow/TidyFlow.app
   # Should output: valid on disk
   ```
4. Check identity:
   ```bash
   codesign -dv /Volumes/TidyFlow/TidyFlow.app 2>&1 | grep Authority
   # Should show your Developer ID
   ```

## Troubleshooting

- **Job fails at import**: Check p12 includes private key
- **Signature invalid**: Verify SIGN_IDENTITY matches exactly
- **spctl fails**: Expected until notarized (D5-3b-3)
