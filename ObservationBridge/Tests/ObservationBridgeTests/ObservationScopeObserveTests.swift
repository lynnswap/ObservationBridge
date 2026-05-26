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

        #expect(passes.snapshot() == [ScopePass(kind: .initial, value: 0, isEnabled: false)])

        model.value = 1
        #expect(await passes.waitUntilValue(ScopePass(kind: .didSet, value: 1, isEnabled: false)))
        #expect(passes.latestValue == ScopePass(kind: .didSet, value: 1, isEnabled: false))

        model.isEnabled = true
        #expect(await passes.waitUntilValue(ScopePass(kind: .didSet, value: 1, isEnabled: true)))
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

        #expect(await passes.waitUntilValue(ScopePass(kind: .initial, value: 0, isEnabled: false)))

        model.value = 7
        #expect(await passes.waitUntilValue(ScopePass(kind: .didSet, value: 7, isEnabled: false)))
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

        #expect(await passes.waitUntilValue(ScopePass(kind: .initial, value: 0, isEnabled: false)))
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

        #expect(await passes.waitUntilValue(ScopePass(kind: .initial, value: 0, isEnabled: false)))

        model.value = 1
        #expect(await passes.waitUntilValue(ScopePass(kind: .didSet, value: 1, isEnabled: false)))

        model.value = 2
        #expect(await passes.waitUntilValue(ScopePass(kind: .didSet, value: 2, isEnabled: false)))
        #expect(await receivesNoNewValue(in: passes))

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

        #expect(await passes.waitUntilValue(ScopePass(kind: .initial, value: 0, isEnabled: false)))
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

        #expect(await values.waitUntilValue(0))
        model.value = 0
        #expect(await receivesNoNewValue(in: values))
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
        #expect(await first.waitUntilValue("first:initial:0"))

        let second = installReplacingObservation(
            observations: observations,
            model: model,
            label: "second"
        )

        #expect(first.isActive == false)
        #expect(await second.waitUntilValue("second:initial:0"))

        model.value = 1
        #expect(await second.waitUntilValue("second:didSet:1"))
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
        #expect(await valuePasses.waitUntilValue("value:initial:value:0"))

        let enabledPasses = installReplacingObservation(
            observations: observations,
            model: model,
            readTarget: .isEnabled,
            label: "enabled"
        )
        #expect(valuePasses.isActive == false)
        #expect(await enabledPasses.waitUntilValue("enabled:initial:isEnabled:false"))

        model.isEnabled = true
        #expect(await enabledPasses.waitUntilValue("enabled:didSet:isEnabled:true"))

        model.value = 1
        #expect(await receivesNoNewValue(in: enabledPasses))
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
        #expect(await initialOnlyPasses.waitUntilValue("initial:initial:0"))
        #expect(initialOnlyPasses.isActive == false)

        let didSetPasses = installReplacingObservation(
            observations: observations,
            model: model,
            options: .didSet,
            label: "did"
        )
        #expect(await didSetPasses.waitUntilValue("did:initial:0"))

        model.value = 1
        #expect(await didSetPasses.waitUntilValue("did:didSet:1"))
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
        #expect(await firstPasses.waitUntilValue("first:initial:0"))

        let secondPasses = installReplacingObservation(
            observations: observations,
            model: secondModel,
            label: "second"
        )
        #expect(firstPasses.isActive == false)
        #expect(await secondPasses.waitUntilValue("second:initial:0"))

        firstModel.value = 1
        #expect(await receivesNoNewValue(in: secondPasses))
        #expect(firstPasses.snapshot() == ["first:initial:0"])
        #expect(secondPasses.snapshot() == ["second:initial:0"])

        secondModel.value = 2
        #expect(await secondPasses.waitUntilValue("second:didSet:2"))
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

        #expect(await passes.waitUntilValue(ScopePass(kind: .initial, value: 0, isEnabled: false)))
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

        #expect(await values.waitUntilValue(0))
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

        #expect(await kinds.waitUntilValue(.initial))
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

        #expect(await kinds.waitUntilValue(.initial))
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
            #expect(await values.waitUntilValue(0))
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

        #expect(await values.waitUntilValue(0))
        #expect(values.snapshot() == [0])

        model.payload = NonSendablePayload(value: 2)
        #expect(await values.waitUntilValue(2))
        #expect(values.snapshot() == [0, 2])
    }

    @Test
    func observeUsesCustomActorIsolationForCallbacks() async {
        let model = CounterModel()
        let probe = CustomActorObservationProbe()

        let values = await probe.observe(model)
        #expect(await values.waitUntilValue(0))

        model.value = 4
        #expect(await values.waitUntilValue(4))
        #expect(values.snapshot() == [0, 4])
        await probe.cancelAll()
    }

    @Test
    func observeTracksMultiplePassesOnCustomActorOwnedModel() async {
        let probe = CustomActorOwnedObservationProbe()

        let values = await probe.observe()
        #expect(await values.waitUntilValue(0))

        await probe.setValue(1)
        #expect(await values.waitUntilValue(1))

        await probe.setValue(2)
        #expect(await values.waitUntilValue(2))
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

        #expect(await values.waitUntilValue(0))

        model.value = 5
        #expect(await values.waitUntilValue(5))
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

private func receivesNoNewValue<Value: Sendable>(
    in values: ObservedValues<Value>,
    timeout: Duration = .milliseconds(100)
) async -> Bool {
    let existingCount = values.snapshot().count
    return await values.waitUntilNewValue(after: existingCount, timeout: timeout) == nil
}
