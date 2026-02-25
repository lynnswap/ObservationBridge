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

### Duplicate suppression (`Equatable` values)

```swift
model.observe(
    \.count,
    removeDuplicates: true
) { value in
    print(value)
}
```

If you need explicit lifecycle control, use `.manual` retention and keep the returned handle:

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
- optionally support duplicate suppression for `Equatable` values (`removeDuplicates: true`)

Legacy backend behavior note:

- legacy coalesces burst mutations and emits the latest observed value instead of replaying every intermediate mutation
- native uses Swift `Observations` transaction semantics on supported OS versions; both backends preserve `latest wins` cancellation for `observeTask`

Note: `.automatic` retention requires Objective-C runtime support. On platforms without it, use `.manual`.
