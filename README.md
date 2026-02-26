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

### Option flags (`ObservationOptions`)

```swift
model.observe(
    \.count,
    options: [.removeDuplicates]
) { value in
    print(value)
}
```

### Debounce

```swift
let debounce = ObservationDebounce(
    interval: .milliseconds(250),
    mode: .immediateFirst // default
)

model.observeTask(
    \.count,
    options: [.debounce(debounce)]
) { value in
    await analytics.trackCount(value)
}
```

`ObservationDebounce` uses millisecond precision. Sub-millisecond durations are rounded to the nearest millisecond.

### Deterministic testing with standard Clock

`observe` / `observeTask` also accept `clock: any Clock<Duration>`.
By default it uses `ContinuousClock()` and keeps the existing behavior.

In tests, pass your own `Clock` implementation to drive debounce timing manually:

```swift
let clock = MyTestClock() // your Clock implementation for tests
let debounce = ObservationDebounce(interval: .milliseconds(250), mode: .delayedFirst)

let handle = model.observeTask(
    \.count,
    options: [.debounce(debounce)],
    clock: clock
) { value in
    await recorder.record(value)
}
defer { handle.cancel() }

await clock.sleep(untilSuspendedBy: 1) // helper provided by your test clock
clock.advance(by: .milliseconds(250))  // deterministic time progression
```

If you need explicit lifecycle control, use `.manual` retention and keep the returned handle:

```swift
let handle = model.observe(
    \.count,
    retention: .manual,
    options: [.removeDuplicates]
) { value in
    print(value)
}

handle.cancel()
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
let stream = makeObservationsCompatStream(backend: .legacy) {
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
- optionally support duplicate suppression for `Equatable` values (`options: [.removeDuplicates]`)
- optionally support debounce (`options: [.debounce(ObservationDebounce(...))]`)
- debounce time progression follows `clock` (`ContinuousClock` by default)

Legacy backend behavior note:

- legacy coalesces burst mutations and emits the latest observed value instead of replaying every intermediate mutation
- native uses Swift `Observations` transaction semantics on supported OS versions; both backends preserve `latest wins` cancellation for `observeTask`
- `latest wins` means newer values are prioritized; when a running task is cancelled, completion timing depends on cooperative cancellation in user task code

Note: `.automatic` retention requires Objective-C runtime support. On platforms without it, use `.manual`.
