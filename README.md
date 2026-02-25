# ObservationsCompat

`ObservationsCompat` is a lightweight compatibility layer for Swift Observation.

It now provides owner-bound APIs designed to remove manual `Task` and `weak self` management:

- `model.observe(...)` for synchronous handlers
- `model.observeTask(...)` for async handlers (`latest wins` cancellation)

Both APIs:

- use native `Observations` on supported OS versions
- fall back to legacy `withObservationTracking` on older OS versions
- auto-cancel when the owner is released (`retention: .automatic`, default)
- optionally support duplicate suppression for `Equatable` values (`removeDuplicates: true`)

Note: `.automatic` retention requires Objective-C runtime support. On platforms without it, use `.manual`.

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

### Async work (`observeTask`)

```swift
import ObservationsCompat

model.observeTask(\.count) { value in
    await analytics.trackCount(value)
}
```

### Multiple key paths

```swift
model.observeTask([\.count, \.isEnabled]) {
    await analytics.trackStateChanged()
}
```

### Duplicate suppression (`Equatable` only)

```swift
let handle = model.observe(
    \.count,
    retention: .manual,
    removeDuplicates: true
) { value in
    print(value)
}

handle.cancel()
```

### Advanced backend control

```swift
model.observeTask(
    \.count,
    backend: .native
) { value in
    await process(value)
}
```
