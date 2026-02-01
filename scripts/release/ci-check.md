# CI Release DMG - Manual Trigger Guide

## How to Trigger Build

1. Go to GitHub repository → **Actions** tab
2. Select **"Build Release DMG"** workflow (left sidebar)
3. Click **"Run workflow"** button (right side)
4. Optional: Check "Skip core rebuild" if testing
5. Click green **"Run workflow"** button

## How to Download Artifact

1. Wait for workflow to complete (green checkmark)
2. Click on the completed run
3. Scroll to **Artifacts** section
4. Click artifact name to download ZIP
5. Extract ZIP to get `TidyFlow-*.dmg`

## Artifact Naming

Format: `TidyFlow-{version}-{build}-{commit_sha}`

Example: `TidyFlow-1.0-1-abc1234`

## Verification

After download:
```bash
# Mount DMG
hdiutil attach TidyFlow-*.dmg

# Check app exists
ls -la /Volumes/TidyFlow/TidyFlow.app

# Unmount
hdiutil detach /Volumes/TidyFlow
```

## Known Limitations

- App is **unsigned** - Gatekeeper will block
- Use **Right-click → Open** to bypass on first run
- Not suitable for distribution to end users

## Next: D5-3b-2 (Signing)

Will add certificate import and code signing.
