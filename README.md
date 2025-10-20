# youtrek

## XcodeGen project

This repository now includes a `project.yml` that mirrors the Swift Package layout. To generate the Xcode project:

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) (e.g. `brew install xcodegen`).
2. Run `xcodegen generate` from the repository root. This will create `YouTrek.xcodeproj` (regenerate after any `project.yml` changes).
3. Open the generated project in Xcode 16+/26, select the `YouTrek` scheme, and press **⌘R** to launch the macOS app.

After generation run `xcodebuild -resolvePackageDependencies -project YouTrek.xcodeproj -scheme YouTrek` (or simply open the project in Xcode and allow it to resolve packages on first build). The generated project references all Swift package dependencies declared in `Package.swift`, targets macOS 15, and produces schemes for both the app and unit tests.
