# ObservationsCompat

`ObservationsCompat` is a compatibility layer for Swift Observation.

It provides two usage styles:

- owner-bound callbacks: `observe` / `observeTask`
- `AsyncSequence` wrappers: `ObservationsCompat` / `makeObservationsCompatStream`

## Requirements

- Swift 6.2
- iOS 18+
- macOS 15+

## Basic Usage

### Synchronous updates (`observe`)

```swift
import ObservationsCompat

model.observe(\.count) { value in
    print("count = \(value)")
}
```

### Async updates (`observeTask`)

```swift
import ObservationsCompat

model.observeTask(\.count) { value in
    await analytics.trackCount(value)
}
```

### Multiple key paths (trigger-only)

```swift
model.observeTask([\.count, \.isEnabled]) {
    await analytics.trackStateChanged()
}
```

### Multiple key paths with value projection

```swift
model.observeTask(
    [\.count, \.isEnabled],
    options: [.removeDuplicates],
    of: { owner in
        (owner.count, owner.isEnabled)
    }
) { state in
    await analytics.trackState(state)
}
```

## Configuration

### Options

Available options:

- `.removeDuplicates`: suppresses consecutive equal values.
- `.debounce(ObservationDebounce)`: coalesces high-frequency updates and emits on debounce boundaries.
- `.legacyBackend` (`iOS 26.0+` / `macOS 26.0+`): forces legacy `withObservationTracking` backend even on modern OS.
- `ObservationDebounce` fields: `interval`, `tolerance` (optional), `mode` (`.immediateFirst` / `.delayedFirst`).

When both options are used together, duplicate suppression is applied to debounced outputs.

### Clock

#### Deterministic testing

In tests, pass your own `Clock` implementation to drive debounce timing manually:

```swift
let clock = MyTestClock() // your Clock implementation for tests
let debounce = ObservationDebounce(interval: .milliseconds(250), mode: .delayedFirst)

let stream = ObservationsCompat(
    options: [.debounce(debounce)],
    clock: clock
) {
    model.count
}

await clock.sleep(untilSuspendedBy: 1) // helper provided by your test clock
clock.advance(by: .milliseconds(250))  // deterministic time progression
```

## AsyncSequence Style

### `ObservationsCompat`

```swift
import ObservationsCompat

let stream = ObservationsCompat {
    model.count
}

for await value in stream {
    print("count = \(value)")
}
```

### `makeObservationsCompatStream`

```swift
let stream = makeObservationsCompatStream {
    model.count
}

for await value in stream {
    print(value)
}
```

## Behavior Notes

Both APIs:

- use native `Observations` on supported OS versions
- fall back to legacy `withObservationTracking` on older OS versions
- auto-cancel when the owner is released (`retention: .automatic`, default)

Backend behavior note:

- by default, native `Observations` is used on `iOS/macOS 26.0+`, and legacy `withObservationTracking` is used on older OS versions
- `.legacyBackend` forces legacy behavior on `iOS/macOS 26.0+`
- legacy coalesces burst mutations and emits the latest observed value instead of replaying every intermediate mutation
- native uses Swift `Observations` transaction semantics; both backends preserve `latest wins` cancellation for `observeTask`
- `latest wins` means newer values are prioritized; when a running task is cancelled, completion timing depends on cooperative cancellation in user task code

Note: `.automatic` retention requires Objective-C runtime support. On platforms without it, use `.manual`.
