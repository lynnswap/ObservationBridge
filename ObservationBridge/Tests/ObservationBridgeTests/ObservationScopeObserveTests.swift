import Observation
import Testing
@testable import ObservationBridge

private struct ScopePass: Sendable, Equatable {
    let kind: ObservationEvent.Kind
    let value: Int
    let isEnabled: Bool
}

private final class WeakDeinitProbeModelBox: @unchecked Sendable {
    weak var model: DeinitProbeCounterModel?
}

@Suite(.serialized)
final class ObservationScopeObserveTests {
    @Test
    func observationEventKindStaticValuesAreEquatable() {
        #expect(ObservationEvent.Kind.initial == .initial)
        #expect(ObservationEvent.Kind.didSet == .didSet)
        #expect(ObservationEvent.Kind.initial != .didSet)
        #expect(String(describing: ObservationEvent.Kind.didSet) == "didSet")
    }

    @MainActor
    @Test
    func observeStartsImmediatelyAndTracksPropertiesReadByCallback() async {
        let model = MainActorCounterModel()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let passes = observations.observe(model) { event, model in
            MainActor.assertIsolated()
            return ScopePass(
                kind: event.kind,
                value: model.value,
                isEnabled: model.isEnabled
            )
        }
        var cursor = ObservedValuesCursor(passes)

        #expect(await cursor.next() == ScopePass(kind: .initial, value: 0, isEnabled: false))

        model.value = 1
        #expect(await cursor.next() == ScopePass(kind: .didSet, value: 1, isEnabled: false))
        #expect(passes.latestValue == ScopePass(kind: .didSet, value: 1, isEnabled: false))

        model.isEnabled = true
        #expect(await cursor.next() == ScopePass(kind: .didSet, value: 1, isEnabled: true))
        #expect(passes.latestValue == ScopePass(kind: .didSet, value: 1, isEnabled: true))
    }

    @Test
    func valueProducingObserveWaitsForReturnedValues() async {
        let model = CounterModel()
        model.name = "Loading"
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let titles = observations.observe(model) { _, model in
            model.name
        }

        #expect(await titles.waitUntilValue("Loading"))

        model.name = "Loaded"
        #expect(await titles.waitUntilValue("Loaded"))
        #expect(titles.snapshot() == ["Loading", "Loaded"])
    }

    @Test
    func didSetPassReadsValueAfterMutationBody() async {
        let model = DelayedMutationCounterModel()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let passes = observations.observe(model) { event, model in
            ScopePass(
                kind: event.kind,
                value: model.value,
                isEnabled: false
            )
        }
        var cursor = ObservedValuesCursor(passes)

        #expect(await cursor.next() == ScopePass(kind: .initial, value: 0, isEnabled: false))

        model.value = 7
        #expect(await cursor.next() == ScopePass(kind: .didSet, value: 7, isEnabled: false))
        #expect(passes.latestValue == ScopePass(kind: .didSet, value: 7, isEnabled: false))
    }

    @Test
    func didSetUnavailableFallbackDoesNotEmitStaleDidSet() async {
        _ObservationScopeTesting.forcePublicDidSetFallback.withLock { $0 = true }
        defer {
            _ObservationScopeTesting.forcePublicDidSetFallback.withLock { $0 = false }
        }

        let model = DelayedMutationCounterModel()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let passes = observations.observe(model) { event, model in
            ScopePass(
                kind: event.kind,
                value: model.value,
                isEnabled: false
            )
        }
        var cursor = ObservedValuesCursor(passes)

        #expect(await cursor.next() == ScopePass(kind: .initial, value: 0, isEnabled: false))
        #expect(passes.isActive == false)

        model.value = 11
        #expect(passes.snapshot() == [ScopePass(kind: .initial, value: 0, isEnabled: false)])
    }

    @MainActor
    @Test
    func didSetTrackingIsCancelledAfterEachChange() async {
        let model = MainActorCounterModel()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let passes = observations.observe(model) { event, model in
            MainActor.assertIsolated()
            return ScopePass(
                kind: event.kind,
                value: model.value,
                isEnabled: false
            )
        }
        var cursor = ObservedValuesCursor(passes)

        #expect(await cursor.next() == ScopePass(kind: .initial, value: 0, isEnabled: false))

        model.value = 1
        #expect(await cursor.next() == ScopePass(kind: .didSet, value: 1, isEnabled: false))

        model.value = 2
        #expect(await cursor.next() == ScopePass(kind: .didSet, value: 2, isEnabled: false))
        #expect(await cursor.next(timeout: .milliseconds(100)) == nil)

        #expect(
            passes.snapshot() == [
                ScopePass(kind: .initial, value: 0, isEnabled: false),
                ScopePass(kind: .didSet, value: 1, isEnabled: false),
                ScopePass(kind: .didSet, value: 2, isEnabled: false),
            ]
        )
    }

    @Test
    func emptyOptionsDeliverOnlyInitialEvent() async {
        let model = CounterModel()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let passes = observations.observe(model, options: []) { event, model in
            ScopePass(
                kind: event.kind,
                value: model.value,
                isEnabled: model.isEnabled
            )
        }
        var cursor = ObservedValuesCursor(passes)

        #expect(await cursor.next() == ScopePass(kind: .initial, value: 0, isEnabled: false))
        #expect(passes.isActive == false)

        model.value = 1
        #expect(passes.snapshot() == [ScopePass(kind: .initial, value: 0, isEnabled: false)])
    }

    @Test
    func sameValueReassignmentDoesNotRecordAnotherObservedValue() async {
        let model = CounterModel()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let values = observations.observe(model) { _, model in
            model.value
        }
        var cursor = ObservedValuesCursor(values)

        #expect(await cursor.next() == 0)
        model.value = 0
        #expect(await cursor.next(timeout: .milliseconds(100)) == nil)
        #expect(values.snapshot() == [0])
    }

    @MainActor
    @Test
    func repeatedObserveFromSameCallSiteReplacesCallbackWithoutDuplicatingPipeline() async {
        let model = MainActorCounterModel()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let first = installReplacingObservation(
            observations: observations,
            model: model,
            label: "first"
        )
        var firstCursor = ObservedValuesCursor(first)
        #expect(await firstCursor.next() == "first:initial:0")

        let second = installReplacingObservation(
            observations: observations,
            model: model,
            label: "second"
        )
        var secondCursor = ObservedValuesCursor(second)

        #expect(first.isActive == false)
        #expect(await secondCursor.next() == "second:initial:0")

        model.value = 1
        #expect(await secondCursor.next() == "second:didSet:1")
        #expect(first.snapshot() == ["first:initial:0"])
        #expect(second.snapshot() == ["second:initial:0", "second:didSet:1"])
    }

    @MainActor
    @Test
    func repeatedObserveFromSameCallSiteRetracksReplacementCallbackBody() async {
        let model = MainActorCounterModel()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let valuePasses = installReplacingObservation(
            observations: observations,
            model: model,
            readTarget: .value,
            label: "value"
        )
        var valueCursor = ObservedValuesCursor(valuePasses)
        #expect(await valueCursor.next() == "value:initial:value:0")

        let enabledPasses = installReplacingObservation(
            observations: observations,
            model: model,
            readTarget: .isEnabled,
            label: "enabled"
        )
        var enabledCursor = ObservedValuesCursor(enabledPasses)
        #expect(valuePasses.isActive == false)
        #expect(await enabledCursor.next() == "enabled:initial:isEnabled:false")

        model.isEnabled = true
        #expect(await enabledCursor.next() == "enabled:didSet:isEnabled:true")

        model.value = 1
        #expect(await enabledCursor.next(timeout: .milliseconds(100)) == nil)
        #expect(
            enabledPasses.snapshot() == [
                "enabled:initial:isEnabled:false",
                "enabled:didSet:isEnabled:true",
            ]
        )
    }

    @MainActor
    @Test
    func repeatedObserveFromSameCallSiteWithDifferentOptionsReplacesPipeline() async {
        let model = MainActorCounterModel()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let initialOnlyPasses = installReplacingObservation(
            observations: observations,
            model: model,
            options: [],
            label: "initial"
        )
        var initialOnlyCursor = ObservedValuesCursor(initialOnlyPasses)
        #expect(await initialOnlyCursor.next() == "initial:initial:0")
        #expect(initialOnlyPasses.isActive == false)

        let didSetPasses = installReplacingObservation(
            observations: observations,
            model: model,
            options: .didSet,
            label: "did"
        )
        var didSetCursor = ObservedValuesCursor(didSetPasses)
        #expect(await didSetCursor.next() == "did:initial:0")

        model.value = 1
        #expect(await didSetCursor.next() == "did:didSet:1")
        #expect(didSetPasses.snapshot() == ["did:initial:0", "did:didSet:1"])
    }

    @MainActor
    @Test
    func repeatedObserveFromSameCallSiteWithDifferentOwnerReplacesPipeline() async {
        let firstModel = MainActorCounterModel()
        let secondModel = MainActorCounterModel()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let firstPasses = installReplacingObservation(
            observations: observations,
            model: firstModel,
            label: "first"
        )
        var firstCursor = ObservedValuesCursor(firstPasses)
        #expect(await firstCursor.next() == "first:initial:0")

        let secondPasses = installReplacingObservation(
            observations: observations,
            model: secondModel,
            label: "second"
        )
        var secondCursor = ObservedValuesCursor(secondPasses)
        #expect(firstPasses.isActive == false)
        #expect(await secondCursor.next() == "second:initial:0")

        firstModel.value = 1
        #expect(await secondCursor.next(timeout: .milliseconds(100)) == nil)
        #expect(firstPasses.snapshot() == ["first:initial:0"])
        #expect(secondPasses.snapshot() == ["second:initial:0"])

        secondModel.value = 2
        #expect(await secondCursor.next() == "second:didSet:2")
        #expect(secondPasses.snapshot() == ["second:initial:0", "second:didSet:2"])
    }

    @Test
    func cancelAllStopsLaterEvents() async {
        let model = CounterModel()
        let observations = ObservationScope()

        let passes = observations.observe(model) { event, model in
            ScopePass(
                kind: event.kind,
                value: model.value,
                isEnabled: model.isEnabled
            )
        }
        var cursor = ObservedValuesCursor(passes)

        #expect(await cursor.next() == ScopePass(kind: .initial, value: 0, isEnabled: false))
        observations.cancelAll()
        #expect(passes.isActive == false)

        model.value = 1
        #expect(passes.snapshot() == [ScopePass(kind: .initial, value: 0, isEnabled: false)])
    }

    @Test
    func observedValuesCancelStopsLaterEvents() async {
        let model = CounterModel()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let values = observations.observe(model) { _, model in
            model.value
        }
        var cursor = ObservedValuesCursor(values)

        #expect(await cursor.next() == 0)
        values.cancel()
        #expect(values.isActive == false)

        model.value = 1
        #expect(values.snapshot() == [0])
    }

    @Test
    func eventCancelStopsCurrentObservationOnly() async {
        let model = CounterModel()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let kinds = observations.observe(model) { event, model in
            _ = model.value
            event.cancel()
            return event.kind
        }
        var cursor = ObservedValuesCursor(kinds)

        #expect(await cursor.next() == .initial)
        #expect(kinds.isActive == false)

        model.value = 1
        #expect(kinds.snapshot() == [.initial])
    }

    @Test
    func cancelAllDuringInitialCallbackStopsCurrentObservation() async {
        let model = CounterModel()
        let probe = ObservationScopeCancellationProbe()
        let observations = probe.observations
        defer { observations.cancelAll() }

        let kinds = observations.observe(model) { event, model in
            _ = model.value
            probe.cancelAll()
            return event.kind
        }
        var cursor = ObservedValuesCursor(kinds)

        #expect(await cursor.next() == .initial)
        #expect(kinds.isActive == false)

        model.value = 1
        #expect(kinds.snapshot() == [.initial])
    }

    @Test
    func reservedStartDoesNotRunAfterSlotCancellation() async {
        let model = CounterModel()
        let state = ScopedObservationState()
        let taskBox = ObservationTaskBox()
        let handle = ObservationHandle {
            state.terminate()
            taskBox.finish()
        }
        let started = ObservedValues<String>()
        let slot = ObservationScopeSlot(
            descriptor: ObservationScopeDescriptor(
                owner: model,
                options: .didSet,
                observationIsolation: nil,
                callbackIsolation: nil
            ),
            state: state,
            handle: handle,
            taskBox: taskBox,
            callbackBox: ObservationScopeCallbackBox<CounterModel> { _, _ in }
        ) { _ in
            started.record("started")
            return Task {}
        }

        let start = slot.reserveStart()
        #expect(start != nil)

        slot.cancel()
        start?()

        #expect(started.snapshot().isEmpty)
        started.cancel()
    }

    @Test
    func initialOnlyObservationReleasesCallbackAfterNaturalCompletion() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let didDeinit = DeinitFlag()

        do {
            let probe = CallbackCaptureProbe {
                Task {
                    await didDeinit.mark()
                }
            }
            let values = observations.observe(model, options: []) { _, model in
                probe.record(model.value)
                return model.value
            }
            var cursor = ObservedValuesCursor(values)
            #expect(await cursor.next() == 0)
        }

        let releasedCallbackCapture = await waitWithTimeout {
            while !(await didDeinit.didDeinit) {
                if Task.isCancelled {
                    return false
                }
                await Task.yield()
            }
            return true
        }
        #expect(releasedCallbackCapture == true)
        observations.cancelAll()
    }

    @Test
    func observeDoesNotRetainOwner() async {
        let observations = ObservationScope()
        let didDeinit = DeinitFlag()
        let weakModel = WeakDeinitProbeModelBox()

        do {
            let model = DeinitProbeCounterModel {
                Task {
                    await didDeinit.mark()
                }
            }
            weakModel.model = model
            observations.observe(model) { _, model in
                _ = model.value
            }
            #expect(await waitUntilCondition { weakModel.model != nil })
        }

        #expect(await waitUntilCondition { weakModel.model == nil })
        let observedDeinit = await waitWithTimeout {
            while !(await didDeinit.didDeinit) {
                if Task.isCancelled {
                    return false
                }
                await Task.yield()
            }
            return true
        }
        #expect(observedDeinit == true)
        observations.cancelAll()
    }

    @MainActor
    @Test
    func observeSupportsMainActorNonSendableValues() async {
        let model = MainActorNonSendablePayloadModel()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let values = observations.observe(model) { _, model in
            MainActor.assertIsolated()
            return model.payload.value
        }
        var cursor = ObservedValuesCursor(values)

        #expect(await cursor.next() == 0)
        #expect(values.snapshot() == [0])

        model.payload = NonSendablePayload(value: 2)
        #expect(await cursor.next() == 2)
        #expect(values.snapshot() == [0, 2])
    }

    @Test
    func observeUsesCustomActorIsolationForCallbacks() async {
        let model = CounterModel()
        let probe = CustomActorObservationProbe()

        let values = await probe.observe(model)
        var cursor = ObservedValuesCursor(values)
        #expect(await cursor.next() == 0)

        model.value = 4
        #expect(await cursor.next() == 4)
        #expect(values.snapshot() == [0, 4])
        await probe.cancelAll()
    }

    @Test
    func observeTracksMultiplePassesOnCustomActorOwnedModel() async {
        let probe = CustomActorOwnedObservationProbe()

        let values = await probe.observe()
        var cursor = ObservedValuesCursor(values)
        #expect(await cursor.next() == 0)

        await probe.setValue(1)
        #expect(await cursor.next() == 1)

        await probe.setValue(2)
        #expect(await cursor.next() == 2)
        #expect(values.snapshot() == [0, 1, 2])
        await probe.cancelAll()
    }

    @Test
    func observeHopsToExplicitCustomActorIsolation() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let probe = CustomActorObservationProbe()
        defer { observations.cancelAll() }

        let values = await observations.observe(
            model,
            options: .didSet,
            { _, model in
                probe.assumeIsolated { isolatedProbe in
                    isolatedProbe.preconditionIsolated()
                    return model.value
                }
            },
            isolation: probe
        )
        var cursor = ObservedValuesCursor(values)

        #expect(await cursor.next() == 0)

        model.value = 5
        #expect(await cursor.next() == 5)
        #expect(values.snapshot() == [0, 5])
    }
}

private enum ReplacementReadTarget {
    case value
    case isEnabled
}

@discardableResult
private func installReplacingObservation(
    observations: ObservationScope,
    model: CounterModel,
    options: ObservationOptions = .didSet,
    label: String
) -> ObservedValues<String> {
    observations.observe(model, options: options) { event, model in
        "\(label):\(event.kind):\(model.value)"
    }
}

@MainActor
@discardableResult
private func installReplacingObservation(
    observations: ObservationScope,
    model: MainActorCounterModel,
    options: ObservationOptions = .didSet,
    label: String
) -> ObservedValues<String> {
    observations.observe(model, options: options) { event, model in
        MainActor.assertIsolated()
        return "\(label):\(event.kind):\(model.value)"
    }
}

@discardableResult
private func installReplacingObservation(
    observations: ObservationScope,
    model: CounterModel,
    readTarget: ReplacementReadTarget,
    label: String
) -> ObservedValues<String> {
    observations.observe(model) { event, model in
        switch readTarget {
        case .value:
            return "\(label):\(event.kind):value:\(model.value)"
        case .isEnabled:
            return "\(label):\(event.kind):isEnabled:\(model.isEnabled)"
        }
    }
}

@MainActor
@discardableResult
private func installReplacingObservation(
    observations: ObservationScope,
    model: MainActorCounterModel,
    readTarget: ReplacementReadTarget,
    label: String
) -> ObservedValues<String> {
    observations.observe(model) { event, model in
        MainActor.assertIsolated()
        switch readTarget {
        case .value:
            return "\(label):\(event.kind):value:\(model.value)"
        case .isEnabled:
            return "\(label):\(event.kind):isEnabled:\(model.isEnabled)"
        }
    }
}

private actor CustomActorObservationProbe {
    private let observations = ObservationScope()

    func observe(_ model: CounterModel) -> ObservedValues<Int> {
        observations.observe(model) { _, model in
            self.preconditionIsolated()
            return model.value
        }
    }

    func cancelAll() {
        observations.cancelAll()
    }
}

private actor CustomActorOwnedObservationProbe {
    private let observations = ObservationScope()
    private let model = CounterModel()

    func observe() -> ObservedValues<Int> {
        observations.observe(model) { _, model in
            self.preconditionIsolated()
            return model.value
        }
    }

    func setValue(_ value: Int) {
        preconditionIsolated()
        model.value = value
    }

    func cancelAll() {
        observations.cancelAll()
    }
}

private struct ObservedValuesCursor<Value: Sendable> {
    private let values: ObservedValues<Value>
    private var nextIndex = 0

    init(_ values: ObservedValues<Value>) {
        self.values = values
    }

    mutating func next(timeout: Duration = .seconds(5)) async -> Value? {
        let snapshot = values.snapshot()
        if nextIndex < snapshot.count {
            defer {
                nextIndex += 1
            }
            return snapshot[nextIndex]
        }

        guard let value = await values.waitUntilNewValue(after: nextIndex, timeout: timeout) else {
            return nil
        }
        nextIndex += 1
        return value
    }
}
