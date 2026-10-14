# ``ObservationBridge``

Write continuous Observation callbacks with a portable `withContinuousObservation`-style API.

## Overview

Start an observation with ``withPortableContinuousObservation(options:apply:_:)``
and read the observable properties you want to track in its callback. Retain the
returned ``PortableObservationTracking/Token`` for as long as you need updates.
The callback inherits the caller's actor context and observes subsequent changes
with the `.didSet` option by default.

Runtime preparation happens automatically when needed. You can optionally call
``PortableObservationTracking/prepare()`` during asynchronous application setup
to warm up the runtime. An observation can start before preparation finishes;
synchronous startup searches for its runtime support or joins the running work
it needs.

ObservationBridge requires Swift 6.3 or later and supports iOS 18.4+, Mac Catalyst
18.4+, macOS 15.4+, tvOS 18.4+, watchOS 11.4+, and visionOS 2.4+. Add
`https://github.com/lynnswap/ObservationBridge.git` as a Swift Package Manager
dependency and select the `ObservationBridge` product for your target.

See <doc:ContinuousObservation> for callback timing, event options, and key-path
matching, and <doc:TestingObservation> for synchronizing tests with rendered
values.

## Topics

### Guides

- <doc:ContinuousObservation>
- <doc:TestingObservation>
- <doc:Migration>

### Continuous observation

- ``PortableObservationTracking/prepare()``
- ``withPortableContinuousObservation(options:apply:_:)``
- ``PortableObservationTracking``
- ``PortableObservationTracking/Options``
- ``PortableObservationTracking/Event``
- ``PortableObservationTracking/Token``

### Tracking failures

- ``PortableObservationTracking/Error``
- ``PortableObservationTracking/Token/error``

### Testing observation delivery

- ``ObservedValues``
