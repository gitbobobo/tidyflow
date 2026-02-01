# D5-3b-1: Minimal CI Workflow for DMG Build

## Overview

This document describes the GitHub Actions workflow for building unsigned DMG artifacts.

## Workflow: `release-dmg.yml`

### Trigger
- **workflow_dispatch** (manual trigger only)
- Optional input: `skip_core` to skip Rust core rebuild

### Runner
- `macos-latest` (GitHub-hosted macOS runner)
- Includes Xcode and standard build tools

### Steps
1. Checkout repository
2. Setup Rust stable toolchain
3. Cache Cargo registry and build artifacts
4. Read version from Xcode project
5. Run `build_dmg.sh` (unsigned)
6. Verify DMG output
7. Upload as workflow artifact

### Artifact
- **Name format:** `TidyFlow-{version}-{build}-{sha}`
- **Contents:** `dist/TidyFlow-{version}-{build}.dmg`
- **Retention:** 14 days

## File Locations

| File | Purpose |
|------|---------|
| `.github/workflows/release-dmg.yml` | CI workflow definition |
| `scripts/release/build_dmg.sh` | DMG build script |
| `scripts/release/read_version.sh` | Version extraction |
| `dist/TidyFlow-*.dmg` | Build output |

## Limitations (This Phase)

1. **No code signing** - DMG and app are unsigned
2. **No notarization** - Cannot pass Gatekeeper without right-click
3. **No GitHub Release** - Artifact only, not published
4. **No tag trigger** - Manual dispatch only

## Next Steps

| Phase | Task | Description |
|-------|------|-------------|
| D5-3b-2 | Import certificates | Add signing identity via secrets |
| D5-3b-3 | Notarization | Add Apple API key, run notarytool |
| D5-3c | GitHub Release | Create release on tag push |
| D5-4 | Sparkle | Auto-update appcast generation |

## Security Considerations

- No secrets required for this phase
- Future phases will need:
  - `APPLE_CERTIFICATE_P12` (base64 encoded)
  - `APPLE_CERTIFICATE_PASSWORD`
  - `APPLE_TEAM_ID`
  - `APPLE_API_KEY_ID`
  - `APPLE_API_KEY_ISSUER`
  - `APPLE_API_KEY_P8` (base64 encoded)

## Testing

1. Push workflow to repository
2. Go to Actions tab
3. Select "Build Release DMG"
4. Click "Run workflow"
5. Download artifact from completed run
