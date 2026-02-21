# ObservationsCompat

`ObservationsCompat` is a small compatibility layer for Swift Observation streams.

It provides a single async-sequence API that:

- uses native `Observations` on supported OS versions
- falls back to a legacy `withObservationTracking`-based stream on older OS versions
- suppresses duplicate consecutive values (`Equatable`)

## Requirements

- Swift 6.2
- iOS 18+
- macOS 15+

## Basic Usage

```swift
import ObservationsCompat

let stream = makeObservationsCompatStream {
    model.count
}

Task {
    for await value in stream {
        print(value)
    }
}
```

## Notes

- The API is designed to keep app code the same across OS versions.
- Cancel the consuming task when the stream is no longer needed.
