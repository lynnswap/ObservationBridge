# Migration

Update existing integrations when upgrading ObservationBridge.

Use the notes for the version you are upgrading to.

## Unreleased

- Call `try await PortableObservationTracking.prepare()` during application setup
  and await completion before starting observations that track mutations.
- The start function now throws. Add `try` and handle startup failures; inspect
  `token.error` if a running observation stops because tracking failed.
- The minimum OS versions now match ABIBridge 0.8.0: iOS and Mac Catalyst 18.4,
  macOS 15.4, tvOS 18.4, watchOS 11.4, and visionOS 2.4.

```swift
try await PortableObservationTracking.prepare()
let token = try withPortableContinuousObservation { event in
    render(model, reason: event.kind)
}
```

Initial-only observations using `options: []` do not require preparation. See
<doc:ContinuousObservation> for callback timing and failure behavior.

## v0.12.0

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

## v0.9.0

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
