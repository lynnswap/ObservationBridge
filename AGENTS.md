# Repository Guidelines

## Test Commands
- `xcodebuild -workspace ObservationBridge.xcworkspace -scheme ObservationBridgeTests -destination 'platform=macOS' test`
  - Run macOS test suite via workspace scheme.

## Coding Style & Naming Conventions
- Swift 6.2 / Swift language mode 6 is the baseline.
- Use Xcode default formatting: 4-space indentation, no tabs.
- Follow Swift API Design Guidelines:
  - Types: `UpperCamelCase`
  - Properties/functions: `lowerCamelCase`
- Keep platform-specific files explicit using suffixes like `+iOS.swift` and `+macOS.swift`.
- Prefer small, focused types over large view/controller files.

## Testing Guidelines
- Primary package tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
- MiniApp UI tests use `XCTest` and should remain deterministic (e.g., fixed accessibility identifiers).
- Name tests by behavior, not implementation details (e.g., `automaticThemeResolvesByColorScheme`).
- Add or update tests for every bug fix and public API behavior change.

## Commit & Pull Request Guidelines
- Follow Conventional Commits as seen in history:
  - `perf(legacy): coalesce observation updates and add native stress test`
  - `refactor(observe): make multi-keypath APIs trigger-only`
- Keep commits scoped to one concern.
- PRs should include:
  - Purpose and change summary
  - Linked issue/task (if available)
  - Test commands executed and results
  - Screenshots for MiniApp UI changes
