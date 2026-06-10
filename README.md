# ObservationBridge

ObservationBridge helps non-SwiftUI code consume `@Observable` state changes.

It provides:

- owner-bound callbacks through `ObservationScope`
- `AsyncSequence` streams through `ObservationBridge` / `makeObservationBridgeStream`

## Requirements

- Swift 6.2
- iOS 18+
- macOS 15+

## Owner-Bound Observation

Use `ObservationScope` as the lifecycle owner for UIKit/AppKit views, view
controllers, cells, or other non-SwiftUI objects that render observable state.

```swift
import ObservationBridge

let observations = ObservationScope()

observations.observe(model) { event, model in
    if event.kind == .initial {
        installViewsIfNeeded()
    }

    titleLabel.text = model.title
    countLabel.text = "\(model.count)"
    saveButton.isEnabled = model.canSave
}
```

The callback body is the tracking body. Every observable property read from
`model` inside the callback becomes part of the observation.

When the callback should react differently depending on which property changed,
ask the event with `matches(_:)`. A coalesced pass can stand for multiple
mutations; `matches` returns `true` for every key path that triggered the pass.

```swift
observations.observe(model) { event, model in
    if event.kind == .initial {
        installViewsIfNeeded()
    }

    titleLabel.text = model.title
    countLabel.text = "\(model.count)"

    if event.kind == .initial || event.matches(\Model.count) {
        cache.update(using: model.expensiveValue(for: model.count))
    }
}
```

### Events

Later event options follow Swift's `withContinuousObservation` semantics where
available. `.initial` is the ObservationBridge-specific first pass, delivered
synchronously when observation starts in the owner's current actor context.

`ObservationEvent.kind` describes why the callback is running:

- `.initial`
- `.willSet`
- `.didSet`
- `.deinit`

`ObservationOptions` controls which later events are delivered:

```swift
observations.observe(model, options: .didSet) { event, model in
    render(model)
}

observations.observe(model, options: []) { event, model in
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

Call `ObservationDelivery.cancel()` to stop one observation, or `cancelAll()` to
tear down every observation owned by the scope:

```swift
let delivery = observations.observe(model) { _, model in
    render(model)
}

delivery.cancel()
observations.cancelAll()
```

`ObservationEvent.matches(_:)` reports whether a pass was triggered by a
mutation of the supplied key path, on every supported toolchain and OS.
`.initial` and `.deinit` passes match nothing. When trigger key paths cannot be
captured — backends that run without the tracking SPI, including `.deinit`-enabled
observations on the native backend — `matches` conservatively returns `true` for
every key path so callers never skip work for a mutation that did happen. Key
paths carry no instance identity, so two tracked objects of the same type are
indistinguishable.

## AsyncSequence Style

Use `ObservationBridge` when async backpressure, iteration, or rate limiting is
the natural fit.

```swift
let stream = ObservationBridge {
    model.count
}

for await value in stream {
    print(value)
}
```

`makeObservationBridgeStream` is equivalent:

```swift
let stream = makeObservationBridgeStream {
    model.count
}
```

### Stream Options

`ObservationStreamOptions` configures backend selection and rate limiting for
stream observations.

```swift
let debounce = ObservationDebounce(interval: .milliseconds(250))

let stream = ObservationBridge(
    options: .rateLimit(.debounce(debounce))
) {
    model.count
}
```

Available stream configuration:

- `ObservationStreamOptions(rateLimit:backend:)`
- `.rateLimit(ObservationRateLimit)`
- `.legacyBackend` on iOS 26.0+ / macOS 26.0+
- `ObservationDebounce(interval:tolerance:mode:)`
- `ObservationThrottle(interval:mode:)`

Backend notes:

- automatic stream observations use the legacy `withObservationTracking` loop on Swift 6.2/6.3
- native `withContinuousObservation` integration is reserved for Swift 6.4+
- `.legacyBackend` keeps forcing the legacy backend after native support is added
- non-`Sendable` stream values use the legacy backend

## Testing

The APIs in this section are for tests. Production UIKit/AppKit rendering code
should usually keep using the `Void` callback form shown above:

```swift
observations.observe(model) { _, model in
    titleLabel.text = model.title
}
```

### Owner-Bound UI Rendering Timing

Use `ObservationDelivery` when the behavior under test belongs to a native UI
owner: a view controller, view, cell, toolbar item owner, or AppKit controller
that renders observable state into existing UI objects. Keep the production
callback in the normal `Void` form, and attach a sampler that reads a small
`Sendable` UI-facing snapshot after each delivery.

```swift
struct RenderedState: Sendable, Equatable {
    var primaryText: String?
    var actionEnabled: Bool
}

let delivery = observations.observe(model) { _, model in
    renderNativeViews(from: model)
}

let renderedStates = await delivery.values {
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
should usually be tested directly against the model, without going through
`ObservationBridge`.

`ObservationDelivery.cancel()` cancels the backing observation. `values { ... }`
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
inject a clock into owner-bound observation delivery.

### Stream Rate-Limit Timing

For stream debounce or throttle tests, inject a `Clock` into the stream API
instead:

```swift
let debounce = ObservationDebounce(interval: .milliseconds(250))

let stream = makeObservationBridgeStream(
    options: .rateLimit(.debounce(debounce)),
    clock: testClock
) {
    model.title
}
```

That `clock:` controls stream rate-limit timing only. It is separate from
`ObservedValues` timeouts and from the owner-bound `observe` callback pipeline.

## Migration

### v0.9.0

These notes apply when upgrading from `v0.8.x` or earlier to `v0.9.0`.

- Owner-bound observation now starts from `ObservationScope`. Replace
  `model.observe(...).store(in: observations)` with
  `observations.observe(model) { event, model in ... }`.
- The callback body is now the tracking body. Read every observed property from
  `model` inside the callback instead of passing key paths to `observe`.
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
observations.observe(model) { _, model in
    countLabel.text = "\(model.count)"
}
```

- `observeTask` has been removed without a compatibility shim. For simple
  fire-and-forget work, start a `Task` from `observe` after copying the values
  you need.

```swift
observations.observe(model) { _, model in
    let count = model.count
    Task {
        await analytics.trackCount(count)
    }
}
```

- If ordering, cancellation, or backpressure matter, use `ObservationBridge` or
  `makeObservationBridgeStream` instead of recreating the old `observeTask`
  queueing behavior.
- `id:`, `ObservationScope.update(_:)`, and `ObservationScope.cancel(id:)` have
  been removed. Use one `ObservationScope` per lifecycle owner and call
  `cancelAll()` before rebinding a dynamic set of observations.
- `ObservationOptions` is now an owner-bound event option set. Later event
  options follow `withContinuousObservation`; use `[]` for initial-only
  callbacks.
- `ObservationEvent` is now noncopyable and borrowed by the callback. Save
  `event.kind` instead of storing the event itself.
- `ObservationEvent.matches(_:)` reports the key paths that triggered a pass.
  The explicit `tracking:` observe overload has been removed: read the needed
  properties in the callback and filter passes with `matches(_:)` instead.
- Stream rate-limit and backend settings moved from `ObservationOptions` to
  `ObservationStreamOptions`.
