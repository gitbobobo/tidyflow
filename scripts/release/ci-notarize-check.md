# CI Notarization Checklist

## 1. Create App Store Connect API Key

1. Go to [App Store Connect](https://appstoreconnect.apple.com) > Users and Access > Keys
2. Click "+" to create new key with "Developer" role
3. Download AuthKey_XXXX.p8 (only available once!)
4. Note the Key ID and Issuer ID

## 2. Configure GitHub Secrets

1. Go to repo Settings > Secrets and variables > Actions
2. Add these repository secrets:
   - `ASC_API_KEY_ID` - Key ID from step 1
   - `ASC_API_ISSUER_ID` - Issuer ID from step 1
   - `ASC_API_KEY_P8_BASE64` - Run: `base64 -i AuthKey_XXXX.p8 | pbcopy`

## 3. Trigger Notarized Build

1. Go to Actions > "Build Release DMG"
2. Click "Run workflow"
3. Check both "Sign the app" AND "Notarize the signed app"
4. Click "Run workflow"

## 4. Verify Success

- Workflow completes without errors
- Summary shows "Notarized: Yes" and "Gatekeeper: Accepted"
- Artifact name contains "-notarized"

## 5. Local Verification (Optional)

```bash
# Download and extract artifact
hdiutil attach TidyFlow-*.dmg
spctl --assess --type execute -v /Volumes/TidyFlow/TidyFlow.app
# Should show: accepted source=Notarized Developer ID
```

## Troubleshooting

- **"notarize requires sign"**: Enable both checkboxes
- **Authentication error**: Verify all 3 ASC secrets are set correctly
- **Check notarytool-submit.json**: Download artifact for detailed error info
