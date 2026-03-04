# ObservationBridge

ObservationBridge is an integration layer that provides a consistent API for Swift Observations.

It provides two usage styles:

- owner-bound callbacks: `observe` / `observeTask`
- `AsyncSequence` wrappers: `ObservationBridge` / `makeObservationBridgeStream`

## Requirements

- Swift 6.2
- iOS 18+
- macOS 15+

## Basic Usage

### Synchronous updates (`observe`)

```swift
import ObservationBridge

model.observe(\.count) { value in
    print("count = \(value)")
}
```

### Async updates (`observeTask`)

```swift
import ObservationBridge

model.observeTask(\.count) { value in
    await analytics.trackCount(value)
}
```

### Single key path (no-arg callback)

```swift
model.observe(\.count) {
    analytics.markCountChanged()
}

model.observeTask(\.count) {
    await analytics.markCountChangedAsync()
}
```

### Optional key path values

```swift
model.observe(\.selectedID, options: [.removeDuplicates]) { selectedID in
    print("selectedID = \(String(describing: selectedID))")
}
```

### Early stop with `ObservationHandle`

```swift
import ObservationBridge

let handle = model.observe(\.count) { value in
    print("count = \(value)")
}

// Stop observation when needed.
handle.cancel()
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

## Manual Handle Retention

If you want Combine-like explicit lifetime control, retain handles in `Set<ObservationHandle>`:

```swift
var cancellables = Set<ObservationHandle>()

model.observe(\.count) { value in
    analytics.markCountChanged(value)
}
.store(in: &cancellables)

model.observeTask(\.count) { value in
    await analytics.markCountChangedAsync(value)
}
.store(in: &cancellables)

// Stop all retained observations early.
cancellables.removeAll()
```

Calling `.store(in:)` switches that handle from owner-lifetime automatic retention to explicit `Set`-managed retention.
Stored handles are still cancelled automatically if the observed owner is released.

## Behavior Notes

Both APIs:

- use native `Observations` on supported OS versions
- fall back to legacy `withObservationTracking` on older OS versions
- are retained for the owner's lifetime and auto-cancel when the owner is released
- calling `.store(in:)` opts a handle into explicit `Set`-managed lifetime instead of owner-lifetime automatic retention

Backend behavior note:

- by default, native `Observations` is used on `iOS/macOS 26.0+`, and legacy `withObservationTracking` is used on older OS versions
- `.legacyBackend` forces legacy behavior on `iOS/macOS 26.0+`
- legacy coalesces burst mutations and emits the latest observed value instead of replaying every intermediate mutation
- native uses Swift `Observations` transaction semantics; both backends preserve `latest wins` cancellation for `observeTask`
- `latest wins` means newer values are prioritized; when a running task is cancelled, completion timing depends on cooperative cancellation in user task code
- keeping the returned `ObservationHandle` is optional; use `cancel()` only when early stop is needed
- `cancel()` does not remove handles from your `Set`; remove them explicitly if desired
