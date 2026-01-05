# CI tests on every commit

- Added `.github/workflows/macos-tests.yml` to run `xcodebuild test` on every push and pull request.
- Keeps signing/notarization in the release workflow only.
