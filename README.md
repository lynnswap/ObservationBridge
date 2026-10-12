# ObservationBridge

Use ObservationBridge to write continuous Observation callbacks with a portable
`withContinuousObservation`-style API.

## Requirements

- Swift 6.3+
- iOS 18.4+, Mac Catalyst 18.4+, macOS 15.4+, tvOS 18.4+, watchOS 11.4+, or visionOS 2.4+

## Installation

Add `https://github.com/lynnswap/ObservationBridge.git` as a Swift Package
Manager dependency and select the `ObservationBridge` product for your target.

## Quick start

Call `bindModel()` when the view is ready. Read observable properties in the
callback and retain the returned token for as long as you need updates. Runtime
preparation happens automatically when needed:

```swift
import Observation
import ObservationBridge
import UIKit

@Observable
@MainActor
final class Counter {
    var count = 0
}

@MainActor
final class CounterViewController: UIViewController {
    let model = Counter()
    private var observation: PortableObservationTracking.Token?

    func bindModel() {
        observation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }
            navigationItem.title = "Count: \(model.count)"
        }
    }
}
```

The callback runs initially, then again after the properties it reads change.
Call `observation?.cancel()` to stop updates. Inspect `observation?.error` if
startup or subsequent tracking fails.

You can optionally warm up the runtime during asynchronous application setup:

```swift
extension CounterViewController {
    func prepareAndBindModel() async throws {
        let preparation = Task.detached {
            try await PortableObservationTracking.prepare()
        }

        bindModel()
        try await preparation.value
    }
}
```

This method runs on `MainActor`, as does `bindModel()`. The observation can start
before `prepare()` finishes. It reuses completed preparation and joins any
running runtime work it needs. Synchronous startup can block the caller while
searching or joining that work; asynchronous `prepare()` performs preparation
away from `MainActor`.

## Documentation

See [DocC](https://lynnswap.github.io/ObservationBridge/documentation/observationbridge/)
for API reference and detailed guides:

- [Continuous observation, event timing, and key-path matching](https://lynnswap.github.io/ObservationBridge/documentation/observationbridge/continuousobservation)
- [Testing observation delivery](https://lynnswap.github.io/ObservationBridge/documentation/observationbridge/testingobservation)
- [Migration](https://lynnswap.github.io/ObservationBridge/documentation/observationbridge/migration)
