# Testing observation delivery

Wait for values rendered by an observation callback in tests.

Use `values` in tests to record a sample after each observation callback
finishes.

```swift
struct RenderedState: Sendable, Equatable {
    var title: String?
    var canSave: Bool
}

try await PortableObservationTracking.prepare()
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

Keep the observation token alive while recording samples. Calling
`ObservedValues.cancel()` detaches that recorder's sampler. Cancel the token to
stop observation delivery as well. Previously recorded values remain available
after the recorder finishes or is cancelled.

`values { ... }` returns an `ObservedValues<Value>` recorder. It exposes
`latestValue`, `snapshot()`, `waitUntilValue(_:timeout:)`,
`waitUntil(timeout:_:)`, `cancel()`, and `isActive`. The timeout arguments are
test guards only; they do not change observation delivery.
