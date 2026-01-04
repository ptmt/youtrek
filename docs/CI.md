# CI

This repo uses GitHub Actions to build, sign, and notarize the macOS app.

## Workflow

Workflow file: `.github/workflows/macos-build-sign.yml`

Triggers:
- Manual (`workflow_dispatch`)
- Tag pushes matching `v*`

Artifacts:
- `macos-app` (signed + stapled `.app`)

## Required Secrets

Add the following repository secrets in GitHub:

- `SIGNING_CERTIFICATE`: Base64-encoded `.p12` for the **Developer ID Application** certificate.
- `SIGNING_CERTIFICATE_PASSWORD`: Password for the `.p12`.
- `KEYCHAIN_PASSWORD`: Password used to create the temporary keychain on the runner.
- `APPLE_ID`: Apple ID used for notarization.
- `APPLE_TEAM_ID`: Team ID for the Apple Developer account.
- `APPLE_APP_SPECIFIC_PASSWORD`: App-specific password for the Apple ID.

Optional:
- `MACOS_PROVISIONING_PROFILE`: Base64-encoded `.provisionprofile` (only needed if your project requires it).

## Preparing Secrets (local)

Example commands to create base64 secrets:

```bash
base64 -i "DeveloperID.p12" | pbcopy
base64 -i "MyProfile.provisionprofile" | pbcopy
```

## Notes

- The workflow uses the `YouTrek` scheme from `YouTrek.xcodeproj`.
- Signing method is **developer-id** and requires a Developer ID Application certificate.
- The notarized app is stapled before being uploaded as a build artifact.
