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
- `.rateLimit(ObservationRateLimit)`: explicit rate-limit configuration (`.debounce(...)` / `.throttle(...)`).
- `.legacyBackend` (`iOS 26.0+` / `macOS 26.0+`): forces legacy `withObservationTracking` backend even on modern OS.
- `ObservationDebounce` fields: `interval`, `tolerance` (optional), `mode` (`.immediateFirst` / `.delayedFirst`).
- `ObservationThrottle` fields: `interval`, `mode` (`.latest` / `.earliest`).

Rate-limit notes:

- `debounce` and `throttle` are mutually exclusive; combining different rate-limit options is a configuration conflict.
- `throttle(mode: .latest)` is the default and means: emit the first value immediately, then emit the latest value seen during each interval.
- `throttle(mode: .earliest)` emits the first value seen during each interval after the initial immediate emission.
- When `.removeDuplicates` is combined with a rate limit, duplicate suppression is applied to rate-limited outputs.

### Clock

#### Deterministic testing

In tests, pass your own `Clock` implementation to drive debounce or throttle timing manually:

```swift
let clock = MyTestClock() // your Clock implementation for tests
let throttle = ObservationThrottle(interval: .milliseconds(250))

let stream = ObservationBridge(
    options: [.rateLimit(.throttle(throttle))],
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
- support non-`Sendable` observed values when producer and consumer closures share the same actor isolation
- create a fresh observation pipeline for each `ObservationBridge` iterator
- require retaining the returned `ObservationHandle` to keep observation active
- cancel automatically if the observed owner is released

Backend behavior note:

- by default, native `Observations` is used on `iOS/macOS 26.0+`, and legacy `withObservationTracking` is used on older OS versions
- `.legacyBackend` forces legacy behavior on `iOS/macOS 26.0+`
- legacy coalesces burst mutations and emits the latest observed value instead of replaying every intermediate mutation
- native uses Swift `Observations` transaction semantics
- `observeTask` never cancels in-flight work; it preserves the next selected output, then coalesces any additional backlog to the latest pending value
- non-`Sendable` values always use the legacy backend, even on `iOS/macOS 26.0+`
- non-`Sendable` observation preconditions producer/callback isolation equality; mismatch traps at runtime
- with `.removeDuplicates`, coalescing still avoids re-emitting a value that duplicates the currently delivered one
- keep the returned `ObservationHandle` (or store it in `Set<ObservationHandle>`) while observation should continue
- `cancel()` does not remove handles from your `Set`; remove them explicitly if desired

## Migration

### v0.6.0

- `.debounce(ObservationDebounce)` is deprecated; use `.rateLimit(.debounce(...))` instead.
- Inspect `options.rateLimit` instead of relying on the deprecated `options.debounce` convenience accessor.

### v0.5.0

- Up to `v0.4.x`, `observe` / `observeTask` included owner-lifetime automatic handle retention.
- Starting with `v0.5.0`, automatic handle retention is no longer supported.
- Retain the returned `ObservationHandle` explicitly (for example, a stored property or `Set<ObservationHandle>`), or observation will stop when the handle is released.
