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

Prepare the runtime once during asynchronous application setup and await completion
before starting observations that track mutations:

```swift
try await PortableObservationTracking.prepare()
```

Then call `bindModel()` when the view is ready. Read observable properties in the
callback and retain the returned token for as long as you need updates:

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

The callback inherits the caller's actor context and runs an initial tracking
pass, then runs again after tracked values change by default. Read the values
you want to keep observing on every pass. Call `observation?.cancel()` to stop
updates early; releasing the token also cancels the observation. Preparation
throws if the required SPI cannot be resolved and no native fallback is available.
The start call is nonthrowing. Starting a mutation observation before preparation
returns an inactive token with `PortableObservationTracking.Error.notPrepared`.
Startup and later tracking failures stop the observation and are available through
`observation?.error`.

## Documentation

See [DocC](https://lynnswap.github.io/ObservationBridge/documentation/observationbridge/)
for API reference and detailed guides:

- [Continuous observation, event timing, and key-path matching](https://lynnswap.github.io/ObservationBridge/documentation/observationbridge/continuousobservation)
- [Testing observation delivery](https://lynnswap.github.io/ObservationBridge/documentation/observationbridge/testingobservation)
- [Migration](https://lynnswap.github.io/ObservationBridge/documentation/observationbridge/migration)
