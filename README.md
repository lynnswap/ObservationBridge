# ObservationBridge

ObservationBridge helps non-SwiftUI code consume `@Observable` state changes.

It provides:

- a portable `withContinuousObservation`-style API for Swift 6.2+ deployment targets

## Requirements

- Swift 6.2
- iOS 18+
- macOS 15+

## Portable Continuous Observation

Use `withPortableContinuousObservation` where you would use Swift's
`withContinuousObservation`, but need the same callback shape on older
deployment targets. Keep the returned token alive for as long as the observation
should run.

```swift
import ObservationBridge

let token = withPortableContinuousObservation { event in
    if event.kind == .initial {
        installViewsIfNeeded()
    }

    titleLabel.text = model.title
    countLabel.text = "\(model.count)"
    saveButton.isEnabled = model.canSave
}
```

The callback body is the tracking body. Every observable property read inside
the callback becomes part of the observation.

When the callback should react differently depending on which property changed,
ask the event with `matches(_:)`. A coalesced pass can stand for multiple
mutations; `matches` returns `true` for every key path that triggered the pass.

```swift
let token = withPortableContinuousObservation { event in
    if event.kind == .initial {
        installViewsIfNeeded()
    }

    titleLabel.text = model.title
    countLabel.text = "\(model.count)"

    if event.kind == .initial || event.matches(\Model.rows) {
        applySnapshot(
            model.rows,
            animatingDifferences: event.kind != .initial
        )
    }
}
```

### Events

Later event options follow Swift's `withContinuousObservation` semantics where
available. `.initial` is the portable API's first pass, delivered synchronously
when observation starts in the caller's current actor context.

`ObservationEvent.kind` describes why the callback is running:

- `.initial`
- `.willSet`
- `.didSet`
- `.deinit`

`ObservationOptions` controls which later events are delivered:

```swift
let token = withPortableContinuousObservation(options: .didSet) { event in
    render(model)
}

let initialOnlyToken = withPortableContinuousObservation(options: []) { event in
    renderOnce(model)
}
```

`[]` delivers only `.initial`. `.didSet` and `.willSet` deliver `.initial` plus
later events on every supported toolchain. Swift 6.4 with OS 27+ adds native
`.deinit`. Availability-limited events are not synthesized by the legacy
backend.

`ObservationEvent` is borrowed for the callback lifetime. Save `event.kind` if
later code needs the reason for the pass. `event.cancel()` cancels backing
tracking when one is available, including during the synchronous initial pass.

Call `PortableObservationToken.cancel()` to stop one observation. The token also
cancels when it deinitializes:

```swift
let token = withPortableContinuousObservation { _ in
    render(model)
}

token.cancel()
```

`ObservationEvent.matches(_:)` reports whether a pass was triggered by a
mutation of the supplied key path, on every supported toolchain and OS.
`.initial` and `.deinit` passes match nothing. When trigger key paths cannot be
captured — backends that run without the tracking SPI, including `.deinit`-enabled
observations on the native backend — `matches` conservatively returns `true` for
every key path so callers never skip work for a mutation that did happen. Key
paths carry no instance identity, so two tracked objects of the same type are
indistinguishable.

## Testing

The APIs in this section are for tests. Production UIKit/AppKit rendering code
should usually keep using the `Void` callback form shown above:

```swift
let token = withPortableContinuousObservation { _ in
    titleLabel.text = model.title
}
```

### Native UI Rendering Timing

Use `PortableObservationToken` when the behavior under test belongs to a native UI
owner: a view controller, view, cell, toolbar item owner, or AppKit controller
that renders observable state into existing UI objects. Keep the production
callback in the normal `Void` form, and attach a sampler that reads a small
`Sendable` UI-facing snapshot after each delivery.

```swift
struct RenderedState: Sendable, Equatable {
    var primaryText: String?
    var actionEnabled: Bool
}

let token = withPortableContinuousObservation { _ in
    renderNativeViews(from: model)
}

let renderedStates = await token.values {
    RenderedState(
        primaryText: primaryTextForTesting,
        actionEnabled: actionButton.isEnabled
    )
}

triggerModelChange()

#expect(await renderedStates.waitUntilValue(
    RenderedState(primaryText: expectedText, actionEnabled: true)
))
```

Sample rendered facts such as label text, enabled state, selected identifiers,
row counts, accessibility values, presentation state, or native object identity.
Do not install a second observation just to wait for the raw model value; that
does not prove the production callback has rendered. Pure model state changes
should usually be tested directly against the model, without observing rendered
UI delivery.

`PortableObservationToken.cancel()` cancels the backing observation. `values { ... }`
returns an `ObservedValues<Value>` recorder for one sampled value stream.
Awaiting `values { ... }` registers the sampler and, when the observation has
already delivered once, samples the current rendered state before returning.
`ObservedValues<Value>` is limited to `Value: Sendable` because values can cross
an async boundary while tests wait. It exposes `latestValue`, `snapshot()`,
`waitUntilValue(_:timeout:)`, `waitUntil(timeout:_:)`, `cancel()`, and
`isActive`. Keep the `ObservedValues` instance alive for as long as the test
expects updates; call `cancel()` when the test no longer needs that sampled
stream.

The `timeout` on `ObservedValues` wait methods is only a test guard. It does not
inject a clock into portable observation delivery.

## Migration

### Next

These notes apply when upgrading from the `ObservationScope.observe` API.

- `ObservationScope` and `.observe(model)` have been removed from the public
  API. Use `withPortableContinuousObservation(options:apply:)` and keep the
  returned `PortableObservationToken` alive.
- The callback now matches Swift's `withContinuousObservation` shape. Read
  observable values directly from the callback body instead of receiving a
  `model` argument.
- `ObservationDelivery` has been replaced by `PortableObservationToken`.
  Attach test samplers with `token.values { ... }`.

```swift
let token = withPortableContinuousObservation { event in
    titleLabel.text = model.title

    if event.kind == .initial || event.matches(\Model.rows) {
        applySnapshot(model.rows)
    }
}
```

### v0.9.0

These notes apply when upgrading from `v0.8.x` or earlier to `v0.9.0`.

- Observation now starts from `withPortableContinuousObservation`. Replace
  `model.observe(...).store(in: observations)` with a retained
  `PortableObservationToken`.
- The callback body is now the tracking body. Read every observed property
  inside the callback instead of passing key paths to `observe`.
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
private var countObservation: PortableObservationToken?

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
  start a `Task` from the observation callback after copying the values you need. Keep any
  ordering, cancellation, backpressure, debounce, or throttle policy in the
  owner that starts that task.

```swift
private var countObservation: PortableObservationToken?

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
- `ObservationOptions` is now a portable event option set. Later event options
  follow `withContinuousObservation`; use `[]` for initial-only callbacks.
- `ObservationEvent` is now noncopyable and borrowed by the callback. Save
  `event.kind` instead of storing the event itself.
- `ObservationEvent.matches(_:)` reports the key paths that triggered a pass.
  The explicit `tracking:` observe overload has been removed: read the needed
  properties in the callback and filter passes with `matches(_:)` instead.
