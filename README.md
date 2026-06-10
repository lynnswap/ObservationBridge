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

When the callback needs to read additional state that should not trigger later
deliveries, pass an explicit `tracking` closure. In that form, only observable
properties read by `tracking` are tracked; `apply` still receives the event and
owner for the initial and selected later deliveries.

```swift
observations.observe(model, tracking: { model in
    _ = model.title
    _ = model.count
}) { event, model in
    if event.kind == .initial {
        installViewsIfNeeded()
    }

    titleLabel.text = model.title
    countLabel.text = "\(model.count)"
    cache.update(using: model.expensiveValue)
}
```

### Events

`ObservationEvent.kind` describes why the callback is running:

- `.initial`: the first tracking pass. Unlike `withContinuousObservation`, this
  is delivered synchronously when observation starts in the owner's current
  actor context.
- `.didSet`: a later pass after observed state changed

`ObservationOptions` controls which later events are delivered:

```swift
observations.observe(model, options: .didSet) { event, model in
    render(model)
}

observations.observe(model, options: []) { event, model in
    renderOnce(model)
}
```

`[]` delivers only `.initial`. `.didSet` delivers `.initial` plus subsequent
change-triggered passes. `.willSet` is intentionally unavailable until the
native Swift 6.4 backend can provide accurate about-to-change timing.

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

`ObservationEvent.matches(_:)` is intentionally unavailable before the Swift 6.4
native backend because the changed key path is not exposed by the older public
Observation API.

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
- `ObservationOptions` is now an owner-bound event option set. Use `.didSet` for
  initial + subsequent callbacks, or `[]` for initial-only callbacks.
- `ObservationEvent` is now noncopyable and borrowed by the callback. Save
  `event.kind` instead of storing the event itself.
- `ObservationEvent.matches(_:)` is not exposed on Swift 6.3 and earlier. It is
  reserved for the Swift 6.4 native backend where stdlib exposes matching.
- Stream rate-limit and backend settings moved from `ObservationOptions` to
  `ObservationStreamOptions`.
