# Continuous observation

Track observable values and choose which changes trigger your callback.

Call `try await PortableObservationTracking.prepare()` once during application
setup and await completion before starting mutation observations. Repeated
successful calls reuse the prepared state. Initial-only observations with
`options: []` do not require preparation.

Create an observation with `try withPortableContinuousObservation(options:apply:)`.
The callback inherits the caller's actor context like Swift's native
`withContinuousObservation`. The returned `PortableObservationTracking.Token`
keeps the observation alive.

```swift
import ObservationBridge

private var observation: PortableObservationTracking.Token?

func bindModel() throws {
    observation = try withPortableContinuousObservation { [weak self] event in
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

## Events

On the exact runtime path, `withPortableContinuousObservation` runs its `.initial`
pass synchronously when the observation starts. That pass is the first tracking
pass. Observable values read during `.initial` become the dependencies that
allow later `.willSet` and `.didSet` passes to fire.

If the OS 27+ liveness fallback is selected because exact Observation runtime
SPI is unavailable, `.initial` follows native timing and may run after the token
is returned.

For the native behavior used as the compatibility reference, see
[Continuous Observation Compatibility Investigation](https://github.com/lynnswap/ObservationBridge/blob/main/Docs/ContinuousObservationCompatibility.md).

Do not return from `.initial` before reading the values you want to keep
tracking:

```swift
let token = try withPortableContinuousObservation { event in
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

- `.initial`: the first tracking pass
- `.willSet`: a tracked dependency emitted a will-set notification
- `.didSet`: a tracked dependency changed

The `.willSet` kind identifies the trigger. The continuous callback follows
observation scheduling, so its reads may already include the new value.

`PortableObservationTracking.Options` controls which later events are delivered. The default is
`.didSet`:

```swift
let didSetObservation = try withPortableContinuousObservation(options: .didSet) { event in
    render(model)
}

let initialOnlyObservation = try withPortableContinuousObservation(options: []) { event in
    renderOnce(model)
}
```

`[]` delivers only `.initial`. `.didSet` and `.willSet` are available on all
supported versions. When both `.willSet` and `.didSet` are requested,
ObservationBridge follows native continuous observation cadence and delivers one
`.didSet` pass for a normal mutation.

Do not store `PortableObservationTracking.Event`. Save `event.kind` if later code needs the
reason for the pass.

Call `PortableObservationTracking.Token.cancel()` to stop an observation. Token
copies share the same observation; cancelling any copy stops it. The observation
also stops when the last token copy is released.

`PortableObservationTracking.Event.matches(_:)` filters the current pass by key
path on the exact runtime path. In the OS 27+ liveness fallback, mutation
matching is conservative and may match unrelated key paths so updates keep
flowing. Treat it as a work filter, not a dependency declaration.

## Failures

Starting a mutation observation before preparation throws
`PortableObservationTracking.Error.notPrepared`. Preparation and startup failures
use Swift errors; handle them in the owner that initializes the observation.
On OS 27+, unavailable exact SPI selects the native liveness fallback described
above. On earlier versions, an unavailable implementation fails preparation or
startup.

An initial tracking failure is thrown by the start call. Later tracking failures
stop the observation and finish its value recorders. Inspect `token.error` for
the first failure. Normal cancellation does not set an error.
