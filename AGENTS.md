# Repository Guidelines

## Project Structure & Module Organization
YouTrek is a Swift Package with the macOS app target under `Sources/YouTrek`. The app layer lives in `Sources/YouTrek/App` (SwiftUI scenes, menus, windows), the domain logic in `Sources/YouTrek/Domain`, data access and integrations in `Sources/YouTrek/Data`, and cross-cutting helpers in `Sources/YouTrek/Infra`. Place any new fixtures or mocks in `Tests/YouTrekTests`, mirroring the source tree. Docs in `docs/` capture architecture and UX—revise them when flows or schemas change. Regenerate the Xcode project with `xcodegen generate` after editing `project.yml`.

## Build, Test, and Development Commands
Use `swift build` to compile via SwiftPM and `swift run YouTrek` for a CLI launch of the app target. `xcodegen generate` recreates `YouTrek.xcodeproj`; follow it with `open YouTrek.xcodeproj` for Xcode work. Run unit tests with `swift test` or `xcodebuild -project YouTrek.xcodeproj -scheme YouTrek test`.

If Xcode or SwiftPM complains about missing symbols or stale project structure after editing Swift sources or `project.yml`, regenerate the project with `xcodegen generate` before debugging further. The generated `.xcodeproj` does not update automatically when new Swift files are added, so running `xcodegen generate` (and reopening the project) should be your first step when you hit unexplained "type not found" errors.

## Coding Style & Naming Conventions
Indent with four spaces and prefer one type per file. Stick to `UpperCamelCase` for types, `lowerCamelCase` for values, and keep enums exhaustive with computed helpers (see `IssuePriority`). Mark async boundaries with `async/await` and adopt `Sendable` or `@MainActor` annotations where concurrency is involved (e.g., repositories, view models). Keep SwiftUI views declarative and split reusable UI into folders mirroring the layout (`App/UI/Sidebar`, `IssueDetail`, etc.).

## Testing Guidelines
Tests use XCTest; new suites should follow the `*Tests.swift` naming used in `YouTrekTests`. Default to the `AppContainer.preview` bootstrap when asserting state so UI remains deterministic. Aim to extend coverage for new features—the `YouTrek` scheme already collects metrics. Run `swift test --enable-code-coverage` locally before submitting substantial changes.

## Commit & Pull Request Guidelines
Commits should be focused, buildable, and use a short Title Case summary similar to `Fix warnings` or `Add initial prototype`. Reference accompanying doc updates in the body and flag breaking changes explicitly. Pull requests need a clear problem statement, validation steps (commands run, screenshots for UI widgets), and links to YouTrack issues when available. Highlight any migrations or manual setup so reviewers and agents can reproduce the environment without guessing.

## Configuration & Security Tips
OAuth configuration and API credentials must never be committed; rely on the AppAuth wrapper plus Keychain storage wired through `AppContainer`. Keep environment-specific values in derived configuration files or Xcode schemes, not in source. When integrating new services, add initialization hooks in `Sources/YouTrek/Infra` and document required secrets under `docs/`.
