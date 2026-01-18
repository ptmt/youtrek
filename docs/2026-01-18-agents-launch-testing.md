# Task Log: Launch + Accessibility/Click Testing Requirement

- Date: 2026-01-18
- Task: Added a repository guideline to require launching the app and validating it via an accessibility framework or by clicking through the UI for every task.
- Files updated:
  - AGENTS.md
- Notes:
  - This doc records the new requirement so future tasks include app launch + interactive verification.
  - Attempted `xcodebuild -project YouTrek.xcodeproj -scheme YouTrek -configuration Debug -destination 'platform=macOS' build` to enable launch/testing, but the build failed with `error: cannot find 'ConflictResolutionDialog' in scope` in `Sources/YouTrek/App/UI/RootView.swift:122`.
