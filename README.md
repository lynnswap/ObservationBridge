# ObservationBridge

Use ObservationBridge to write continuous Observation callbacks with a portable
`withContinuousObservation`-style API.

## Requirements

- Swift 6.3
- iOS 18+
- Mac Catalyst 18+
- macOS 15+
- tvOS 18+
- visionOS 2+

## Portable Continuous Observation

Create an observation with `withPortableContinuousObservation(options:apply:)`.
The callback inherits the caller's actor context like Swift's native
`withContinuousObservation`. The returned `PortableObservationTracking.Token`
keeps the observation alive.

```swift
import ObservationBridge

private var observation: PortableObservationTracking.Token?

func bindModel() {
    observation = withPortableContinuousObservation { [weak self] event in
        guard let self else { return }

        titleLabel.text = model.title
        countLabel.text = "\(model.count)"
        saveButton.isEnabled = model.canSave
        // matches only filters the current pass. Read rows outside the branch
        // so row changes continue to trigger future passes.
        _ = model.rows

        if event.kind == .initial || event.matches(\Model.rows) {
            applySnapshot(
                model.rows,
                animatingDifferences: event.kind != .initial
            )
        }
    }
}

deinit {
    observation?.cancel()
}
```

Read the observable values that should keep triggering the callback on every
pass. Use `matches(_:)` to decide whether to perform additional work for a
changed key path, not as the only guard for correctness.

### Events

`withPortableContinuousObservation` intentionally differs from Swift's native
`withContinuousObservation` in one place: it runs its `.initial` pass
synchronously when the observation starts. That pass is still the first tracking
pass. Observable values read during `.initial` become the dependencies that
allow later `.willSet` and `.didSet` passes to fire.

Do not return from `.initial` before reading the values you want to keep
tracking:

```swift
let token = withPortableContinuousObservation { event in
    let title = model.title
    let rows = model.rows

    guard event.kind != .initial else {
        return
    }

    titleLabel.text = title

    if event.matches(\Model.rows) {
        applySnapshot(rows)
    }
}
```

Later passes are controlled by `PortableObservationTracking.Options`.

`PortableObservationTracking.Event.kind` describes why the callback is running:

- `.initial`: the first tracking pass, delivered synchronously by ObservationBridge
- `.willSet`: a tracked dependency is about to change
- `.didSet`: a tracked dependency changed

`PortableObservationTracking.Options` controls which later events are delivered. The default is
`.didSet`:

```swift
let didSetObservation = withPortableContinuousObservation(options: .didSet) { event in
    render(model)
}

let initialOnlyObservation = withPortableContinuousObservation(options: []) { event in
    renderOnce(model)
}
```

`[]` delivers only `.initial`. `.didSet` and `.willSet` are available on all
supported versions.

Do not store `PortableObservationTracking.Event`. Save `event.kind` if later code needs the
reason for the pass.

Call `PortableObservationTracking.Token.cancel()` to stop an observation. The token also
cancels when it deinitializes.

`PortableObservationTracking.Event.matches(_:)` mirrors Swift's
`withContinuousObservation` matching behavior: mutation passes compare the
event's `ObservationTracking.changed` key path with the supplied key path, and
`.initial` matches nothing. Exact matching relies on weak-linked Observation
runtime SPI. When the required symbols are unavailable on Swift 6.4 / OS 27+
runtimes, ObservationBridge falls back to public `withContinuousObservation` so
updates keep flowing in the callback's inherited actor context. In that fallback
only, `.initial` and mutation event cadence follow native continuous timing, and
mutation `matches(_:)` answers conservatively. On older supported runtimes, the
required SPI symbols are part of the development test contract; ObservationBridge
does not partially downgrade
`[.willSet, .didSet]` to a single mutation kind because that would change the
requested event sequence.

## Testing

Use `values` in tests to record a sample after each observation callback
finishes.

```swift
struct RenderedState: Sendable, Equatable {
    var title: String?
    var canSave: Bool
}

let token = withPortableContinuousObservation { _ in
    titleLabel.text = model.title
    saveButton.isEnabled = model.canSave
}

let rendered = await token.values {
    RenderedState(
        title: titleLabel.text,
        canSave: saveButton.isEnabled
    )
}

model.title = "Draft"
model.canSave = true

#expect(await rendered.waitUntilValue(
    RenderedState(title: "Draft", canSave: true)
))
```

Sample small `Sendable` values that describe rendered output, such as label
text, enabled state, selected identifiers, row counts, accessibility values, or
presentation state.

`values { ... }` returns an `ObservedValues<Value>` recorder. It exposes
`latestValue`, `snapshot()`, `waitUntilValue(_:timeout:)`,
`waitUntil(timeout:_:)`, `cancel()`, and `isActive`. The timeout arguments are
test guards only; they do not change observation delivery.

## Migration

Use the notes for the version you are upgrading to.

### v0.12.0

These notes apply when upgrading from `v0.11.x` or earlier to `v0.12.0`.

- `ObservationOptions` has been renamed to
  `PortableObservationTracking.Options`.
- `ObservationEvent` has been renamed to `PortableObservationTracking.Event`.
- `PortableObservationToken` has been renamed to
  `PortableObservationTracking.Token`.
- `ObservationScope` and `.observe(model)` have been removed from the public
  API. Use `withPortableContinuousObservation(options:apply:)` and keep the
  returned `PortableObservationTracking.Token` alive.
- The callback now matches Swift's `withContinuousObservation` shape. Read
  observable values directly from the callback body instead of receiving a
  `model` argument.
- Explicit actor override is not part of the public API. Call
  `withPortableContinuousObservation` from the actor context that should own the
  callback.
- `ObservationDelivery` has been replaced by `PortableObservationTracking.Token`.
  Attach test samplers with `token.values { ... }`.

```swift
let token = withPortableContinuousObservation { event in
    titleLabel.text = model.title

    let rows = model.rows
    if event.kind == .initial || event.matches(\Model.rows) {
        applySnapshot(rows)
    }
}
```

### v0.9.0

These notes apply when upgrading from `v0.8.x` or earlier to `v0.9.0`.

- Start observations with `withPortableContinuousObservation`. Replace
  `model.observe(...).store(in: observations)` with a retained
  `PortableObservationTracking.Token`.
- Read observed values inside the callback instead of passing key paths to
  `observe`.
- `ObservationRegistration` and `.store(in:)` have been removed without a
  compatibility shim.

```swift
model.observe(\.count) { value in
    countLabel.text = "\(value)"
}
.store(in: observations)
```

After:

```swift
private var countObservation: PortableObservationTracking.Token?

func bindCount() {
    countObservation = withPortableContinuousObservation { _ in
        countLabel.text = "\(model.count)"
    }
}

deinit {
    countObservation?.cancel()
}
```

- `observeTask` has been removed without a compatibility shim. For async work,
  start a `Task` from the observation callback after copying the values you need.
  Keep any ordering, cancellation, backpressure, debounce, or throttle policy in
  the owner that starts that task.

```swift
private var countObservation: PortableObservationTracking.Token?

func bindCountTracking() {
    countObservation = withPortableContinuousObservation { _ in
        let count = model.count
        Task {
            await analytics.trackCount(count)
        }
    }
}

deinit {
    countObservation?.cancel()
}
```

- `id:`, `ObservationScope.update(_:)`, and `ObservationScope.cancel(id:)` have
  been removed. Keep and cancel the returned token before rebinding a dynamic
  observation.
- `PortableObservationTracking.Options` is now a portable event option set. Later event options
  follow `withContinuousObservation`; use `[]` for initial-only callbacks.
- `PortableObservationTracking.Event` is now noncopyable and borrowed by the callback. Save
  `event.kind` instead of storing the event itself.
- `PortableObservationTracking.Event.matches(_:)` filters the current pass by
  trigger key path when trigger details are available. The explicit `tracking:`
  observe overload has been removed: read the needed properties in the callback
  and use `matches(_:)` only to gate optional extra work for that pass.
