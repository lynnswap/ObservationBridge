import Observation
import Foundation
import Synchronization
import Testing
@testable import ObservationBridge

@Suite
final class BackendResolutionTests {
    @MainActor
    @Test
    func defaultBackendUsesLegacyUntilNativeContinuousObservationBackendExists() async {
        #expect(resolveBackend(options: ObservationStreamOptions()) == .legacy)

        let model = MainActorCounterModel()
        let stream = ObservationBridge {
            model.value
        }
        let queue = ValueQueue<Int>()
        let consumer = Task<Void, Never> {
            var iterator = stream.makeAsyncIterator()
            while !Task.isCancelled, let value = await iterator.next() {
                await queue.push(value)
            }
        }
        defer { consumer.cancel() }

        #expect(await nextWithTimeout(from: queue) == 0)

        model.value = 7
        #expect(await nextWithTimeout(from: queue) == 7)
    }

    @Test
    func observationStreamOptionsStoresRateLimitConfiguration() {
        let debounce = ObservationDebounce(
            interval: .milliseconds(100),
            tolerance: .milliseconds(20),
            mode: .immediateFirst
        )
        let throttle = ObservationThrottle(
            interval: .milliseconds(120),
            mode: .earliest
        )

        let debounceOptions = ObservationStreamOptions.rateLimit(.debounce(debounce))
        #expect(debounceOptions.rateLimit == .debounce(debounce))
        #expect(debounceOptions.backend == .automatic)
        #expect(debounceOptions == ObservationStreamOptions(rateLimit: .debounce(debounce)))

        let throttleOptions = ObservationStreamOptions.rateLimit(.throttle(throttle))
        #expect(throttleOptions.rateLimit == .throttle(throttle))
        #expect(throttleOptions.backend == .automatic)
        #expect(throttleOptions == ObservationStreamOptions(rateLimit: .throttle(throttle)))
    }

    @Test
    func observationStreamOptionsCanCombineRateLimitAndLegacyBackend() {
        let debounce = ObservationDebounce(
            interval: .milliseconds(80),
            tolerance: .milliseconds(10),
            mode: .delayedFirst
        )
        let options = ObservationStreamOptions(
            rateLimit: .debounce(debounce),
            backend: .legacy
        )

        #expect(options.rateLimit == .debounce(debounce))
        #expect(options.backend == .legacy)
        #expect(options.forcesLegacyBackend)
    }

    @Test
    func observationOptionsDefaultsToDidSet() {
        let options = ObservationOptions.didSet

        #expect(options.contains(.didSet))
        #expect(!ObservationOptions().contains(.didSet))

        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            let deinitOptions: ObservationOptions = [.didSet, .deinit]
            #expect(deinitOptions.contains(.didSet))
            #expect(deinitOptions.contains(.deinit))
        }
        #endif
    }
}
