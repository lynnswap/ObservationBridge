# ObservationBridge

ObservationBridge is an integration layer that provides a consistent API for Swift Observations.

It provides two usage styles:

- owner-bound callbacks: `observe` / `observeTask`
- `AsyncSequence` wrappers: `ObservationBridge` / `makeObservationBridgeStream`

`observe` / `observeTask` return an `ObservationHandle`.
Retain the handle while observation should stay active.

## Requirements

- Swift 6.2
- iOS 18+
- macOS 15+

## Basic Usage

### Synchronous updates (`observe`)

```swift
import ObservationBridge

var cancellables = Set<ObservationHandle>()

model.observe(\.count) { value in
    analytics.markCountChanged(value)
}
.store(in: &cancellables)
```

### Async updates (`observeTask`)

```swift
import ObservationBridge

var cancellables = Set<ObservationHandle>()

model.observeTask(\.count) { value in
    await analytics.trackCount(value)
}
.store(in: &cancellables)
```

### Multiple key paths (trigger-only)

```swift
let stateChangeHandle = model.observeTask([\.count, \.isEnabled]) {
    await analytics.trackStateChanged()
}
```

### Multiple key paths with value projection

```swift
let stateProjectionHandle = model.observeTask(
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

let stream = ObservationBridge(
    options: [.debounce(debounce)],
    clock: clock
) {
    model.count
}

await clock.sleep(untilSuspendedBy: 1) // helper provided by your test clock
clock.advance(by: .milliseconds(250))  // deterministic time progression
```

## AsyncSequence Style

### `ObservationBridge`

```swift
import ObservationBridge

let stream = ObservationBridge {
    model.count
}

for await value in stream {
    print("count = \(value)")
}
```

### `makeObservationBridgeStream`

```swift
let stream = makeObservationBridgeStream {
    model.count
}

for await value in stream {
    print(value)
}
```

## Direct Handle Control

Use direct handle retention if you prefer property-based lifetime control:

```swift
let countHandle = model.observe(\.count) { value in
    print("count = \(value)")
}

// Stop observation when needed.
countHandle.cancel()
```

## Behavior Notes

Both APIs:

- use native `Observations` on supported OS versions
- fall back to legacy `withObservationTracking` on older OS versions
- require retaining the returned `ObservationHandle` to keep observation active
- cancel automatically if the observed owner is released

Backend behavior note:

- by default, native `Observations` is used on `iOS/macOS 26.0+`, and legacy `withObservationTracking` is used on older OS versions
- `.legacyBackend` forces legacy behavior on `iOS/macOS 26.0+`
- legacy coalesces burst mutations and emits the latest observed value instead of replaying every intermediate mutation
- native uses Swift `Observations` transaction semantics; both backends preserve `latest wins` cancellation for `observeTask`
- `latest wins` means newer values are prioritized; when a running task is cancelled, completion timing depends on cooperative cancellation in user task code
- keep the returned `ObservationHandle` (or store it in `Set<ObservationHandle>`) while observation should continue
- `cancel()` does not remove handles from your `Set`; remove them explicitly if desired

## Compatibility Note for v0.5.0

- Up to `v0.4.x`, `observe` / `observeTask` included owner-lifetime automatic handle retention.
- Starting with `v0.5.0`, automatic handle retention is no longer supported.
- Retain the returned `ObservationHandle` explicitly (for example, a stored property or `Set<ObservationHandle>`), or observation will stop when the handle is released.
