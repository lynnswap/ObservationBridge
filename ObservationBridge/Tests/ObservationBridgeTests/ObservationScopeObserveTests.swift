import Observation
import Synchronization
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

        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) {
            #expect(ObservationEvent.Kind.deinit == .deinit)
            #expect(ObservationEvent.Kind.didSet != .deinit)
            #expect(String(describing: ObservationEvent.Kind.deinit) == "deinit")
        }
        #endif
    }

    @Test
    func observeReturnCanBeIgnoredWithoutCancellingObservation() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(-1)
        defer { observations.cancelAll() }

        observations.observe(model) { _, model in
            rendered.set(model.value)
        }

        #expect(rendered.value == 0)

        model.value = 1
        #expect(await waitUntilCondition { rendered.value == 1 })
    }

    @MainActor
    @Test
    func observeStartsImmediatelyAndTracksPropertiesReadByCallback() async {
        let model = MainActorCounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(ScopePass(kind: .initial, value: -1, isEnabled: false))
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { event, model in
            MainActor.assertIsolated()
            rendered.set(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: model.isEnabled
                )
            )
        }
        let passes = await delivery.values {
            MainActor.assertIsolated()
            return rendered.value
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
    func deliveryValuesWaitForRenderedState() async {
        let model = CounterModel()
        model.name = "Loading"
        let observations = ObservationScope()
        let renderedTitle = RenderedValue("")
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { _, model in
            renderedTitle.set(model.name)
        }
        let titles = await delivery.values {
            renderedTitle.value
        }

        #expect(await titles.waitUntilValue("Loading"))

        model.name = "Loaded"
        #expect(await titles.waitUntilValue("Loaded"))
        #expect(titles.snapshot() == ["Loading", "Loaded"])
    }

    @Test
    func deliveryValuesSampleInitialRenderBeforeReturning() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(-1)
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { _, model in
            rendered.set(model.value)
        }
        let values = await delivery.values {
            rendered.value
        }

        #expect(values.snapshot() == [0])
    }

    @Test
    func deliveryValuesHonorClosureIsolationForImmediateAndLaterSamples() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let sampleProbe = MainActorSampleProbe()
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { _, model in
            _ = model.value
        }
        let samples = await delivery.values { @MainActor in
            sampleProbe.next()
        }

        #expect(await samples.waitUntilValue(1))

        model.value = 1
        #expect(await samples.waitUntilValue(2))
    }

    @Test
    func deliveryValuesRegisteredAfterCompletedDeliverySampleBeforeLaterMutation() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(-1)
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { _, model in
            rendered.set(model.value)
        }

        #expect(rendered.value == 0)

        let values = await delivery.values {
            rendered.value
        }
        model.value = 1

        #expect(await values.waitUntilValue(1))
        #expect(values.snapshot() == [0, 1])
    }

    @Test
    func didSetPassReadsValueAfterMutationBody() async {
        let model = DelayedMutationCounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(ScopePass(kind: .initial, value: -1, isEnabled: false))
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { event, model in
            rendered.set(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: false
                )
            )
        }
        let passes = await delivery.values {
            rendered.value
        }
        var cursor = ObservedValuesCursor(passes)

        #expect(await cursor.next() == ScopePass(kind: .initial, value: 0, isEnabled: false))

        model.value = 7
        #expect(await cursor.next() == ScopePass(kind: .didSet, value: 7, isEnabled: false))
        #expect(passes.latestValue == ScopePass(kind: .didSet, value: 7, isEnabled: false))
    }

    @Test
    func samplerlessDeliveryRegisteredAfterDidSetSamplesLatestRender() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(ScopePass(kind: .initial, value: -1, isEnabled: false))
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { event, model in
            rendered.set(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: false
                )
            )
        }

        model.value = 1
        #expect(await waitUntilCondition {
            rendered.value == ScopePass(kind: .didSet, value: 1, isEnabled: false)
        })
        #expect(await waitUntilCondition {
            delivery._isIdleAfterCompletedDeliveryForTesting
        })

        let values = await delivery.values {
            rendered.value
        }

        #expect(values.snapshot() == [ScopePass(kind: .didSet, value: 1, isEnabled: false)])
    }

    @Test
    func didSetUnavailableFallbackDoesNotEmitStaleDidSet() async {
        _ObservationScopeTesting.forcePublicDidSetFallback.withLock { $0 = true }
        defer {
            _ObservationScopeTesting.forcePublicDidSetFallback.withLock { $0 = false }
        }

        let model = DelayedMutationCounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(ScopePass(kind: .initial, value: -1, isEnabled: false))
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { event, model in
            rendered.set(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: false
                )
            )
        }
        let passes = await delivery.values {
            rendered.value
        }
        var cursor = ObservedValuesCursor(passes)

        #expect(await cursor.next() == ScopePass(kind: .initial, value: 0, isEnabled: false))
        #expect(delivery.isActive == false)
        #expect(passes.isActive == false)

        model.value = 11
        #expect(passes.snapshot() == [ScopePass(kind: .initial, value: 0, isEnabled: false)])
    }

    @MainActor
    @Test
    func didSetTrackingIsCancelledAfterEachChange() async {
        let model = MainActorCounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(ScopePass(kind: .initial, value: -1, isEnabled: false))
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { event, model in
            MainActor.assertIsolated()
            rendered.set(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: false
                )
            )
        }
        let passes = await delivery.values {
            MainActor.assertIsolated()
            return rendered.value
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
        let rendered = RenderedValue(ScopePass(kind: .initial, value: -1, isEnabled: false))
        defer { observations.cancelAll() }

        let delivery = observations.observe(model, options: []) { event, model in
            rendered.set(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: model.isEnabled
                )
            )
        }
        let passes = await delivery.values {
            rendered.value
        }
        var cursor = ObservedValuesCursor(passes)

        #expect(await cursor.next() == ScopePass(kind: .initial, value: 0, isEnabled: false))
        #expect(delivery.isActive == false)
        #expect(passes.isActive == false)

        model.value = 1
        #expect(passes.snapshot() == [ScopePass(kind: .initial, value: 0, isEnabled: false)])
    }

    @Test
    func rawDeinitOptionDoesNotSynthesizeLegacyEvent() async {
        #if compiler(>=6.4)
        _ObservationScopeTesting.forcePublicDidSetFallback.withLock { $0 = true }
        defer {
            _ObservationScopeTesting.forcePublicDidSetFallback.withLock { $0 = false }
        }
        #endif

        let model = ChildContainerModel()
        let weakChild = WeakChildProbeModelBox()
        do {
            let child = ChildProbeModel(value: 7)
            weakChild.value = child
            model.child = child
        }
        let observations = ObservationScope()
        let rendered = RenderedValue(ObservationEvent.Kind.didSet)
        defer { observations.cancelAll() }

        let rawDeinitOptions = ObservationOptions(rawValue: 1 << 2)
        let delivery = observations.observe(model, options: rawDeinitOptions) { event, model in
            if let child = model.child {
                _ = child.value
            }
            rendered.set(event.kind)
        }
        let kinds = await delivery.values {
            rendered.value
        }
        var cursor = ObservedValuesCursor(kinds)

        #expect(await cursor.next() == .initial)
        #expect(delivery.isActive == false)

        model.child = nil
        #expect(await waitUntilCondition { weakChild.value == nil })
        #expect(kinds.snapshot() == [.initial])
    }

    #if compiler(>=6.4)
    @Test
    func nativeDeinitOptionDeliversDependencyDeinitEvent() async {
        guard #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) else {
            return
        }

        let model = ChildContainerModel()
        let weakChild = WeakChildProbeModelBox()
        do {
            let child = ChildProbeModel(value: 7)
            weakChild.value = child
            model.child = child
        }
        let observations = ObservationScope()
        let rendered = RenderedValue(ObservationEvent.Kind.didSet)
        defer { observations.cancelAll() }

        let delivery = observations.observe(model, options: .deinit) { event, model in
            if let child = model.child {
                _ = child.value
            }
            rendered.set(event.kind)
        }
        let kinds = await delivery.values {
            rendered.value
        }
        var cursor = ObservedValuesCursor(kinds)

        #expect(await cursor.next() == .initial)
        #expect(weakChild.value != nil)

        model.child = nil

        #expect(await waitUntilCondition { weakChild.value == nil })
        #expect(await cursor.next() == .deinit)
        #expect(kinds.snapshot() == [.initial, .deinit])
    }

    @Test
    func pendingEventKindsCoalesceConsecutiveDuplicatesInOrder() async {
        guard #available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *) else {
            return
        }

        let model = CounterModel()
        let slot = ObservationScopeSlot(
            owner: model,
            options: [.didSet, .deinit],
            observationIsolation: nil,
            delivery: ObservationDelivery(),
            pipeline: TypedObservationScopeImplicitTrackingPipeline<CounterModel> { _, _ in }
        )
        defer { slot.cancel() }

        slot.emitChange(kind: .didSet)
        slot.emitChange(kind: .didSet)
        slot.emitChange(kind: .deinit)

        #expect(await slot.waitForChange() == .didSet)
        #expect(await slot.waitForChange() == .deinit)
    }
    #endif

    @Test
    func sameValueReassignmentDoesNotRecordAnotherObservedValue() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(-1)
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { _, model in
            rendered.set(model.value)
        }
        let values = await delivery.values {
            rendered.value
        }
        var cursor = ObservedValuesCursor(values)

        #expect(await cursor.next() == 0)
        model.value = 0
        #expect(await cursor.next(timeout: .milliseconds(100)) == nil)
        #expect(values.snapshot() == [0])
    }

    @Test
    func samplerReadsDoNotBecomeObservationDependencies() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(-1)
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { _, model in
            rendered.set(model.value)
        }
        let sampledEnabledValues = await delivery.values {
            model.isEnabled
        }
        var cursor = ObservedValuesCursor(sampledEnabledValues)

        #expect(await cursor.next() == false)

        model.isEnabled = true
        #expect(await cursor.next(timeout: .milliseconds(100)) == nil)

        model.value = 1
        #expect(await cursor.next() == true)
        #expect(rendered.value == 1)
        #expect(sampledEnabledValues.snapshot() == [false, true])
    }

    @Test
    func explicitTrackingDoesNotTrackApplyOnlyReads() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(ScopePass(kind: .initial, value: -1, isEnabled: false))
        defer { observations.cancelAll() }

        let delivery = observations.observe(model, tracking: { model in
            _ = model.value
        }) { event, model in
            rendered.set(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: model.secondaryValue > 0
                )
            )
        }
        let passes = await delivery.values {
            rendered.value
        }
        var cursor = ObservedValuesCursor(passes)

        #expect(await cursor.next() == ScopePass(kind: .initial, value: 0, isEnabled: false))

        model.secondaryValue = 1
        #expect(await cursor.next(timeout: .milliseconds(100)) == nil)

        model.value = 2
        #expect(await cursor.next() == ScopePass(kind: .didSet, value: 2, isEnabled: true))
        #expect(
            passes.snapshot() == [
                ScopePass(kind: .initial, value: 0, isEnabled: false),
                ScopePass(kind: .didSet, value: 2, isEnabled: true),
            ]
        )
    }

    @Test
    func explicitTrackingRefreshesDependenciesAfterEachPass() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue("")
        defer { observations.cancelAll() }

        let delivery = observations.observe(model, tracking: { model in
            _ = model.isEnabled
            if model.isEnabled {
                _ = model.secondaryValue
            } else {
                _ = model.value
            }
        }) { event, model in
            rendered.set(
                "\(event.kind):value:\(model.value):secondary:\(model.secondaryValue):enabled:\(model.isEnabled)"
            )
        }
        let values = await delivery.values {
            rendered.value
        }
        var cursor = ObservedValuesCursor(values)

        #expect(await cursor.next() == "initial:value:0:secondary:0:enabled:false")

        model.secondaryValue = 1
        #expect(await cursor.next(timeout: .milliseconds(100)) == nil)

        model.value = 2
        #expect(await cursor.next() == "didSet:value:2:secondary:1:enabled:false")

        model.isEnabled = true
        #expect(await cursor.next() == "didSet:value:2:secondary:1:enabled:true")

        model.value = 3
        #expect(await cursor.next(timeout: .milliseconds(100)) == nil)

        model.secondaryValue = 4
        #expect(await cursor.next() == "didSet:value:3:secondary:4:enabled:true")
    }

    @Test
    func explicitTrackingHonorsInitialOnlyOptions() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(ScopePass(kind: .didSet, value: -1, isEnabled: false))
        defer { observations.cancelAll() }

        let delivery = observations.observe(model, options: [], tracking: { model in
            _ = model.value
        }) { event, model in
            rendered.set(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: model.secondaryValue > 0
                )
            )
        }
        let passes = await delivery.values {
            rendered.value
        }
        var cursor = ObservedValuesCursor(passes)

        #expect(await cursor.next() == ScopePass(kind: .initial, value: 0, isEnabled: false))
        #expect(delivery.isActive == false)
        #expect(passes.isActive == false)

        model.value = 1
        #expect(passes.snapshot() == [ScopePass(kind: .initial, value: 0, isEnabled: false)])
    }

    @Test
    func explicitTrackingUsesDefaultDidSetOptions() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(ScopePass(kind: .initial, value: -1, isEnabled: false))
        defer { observations.cancelAll() }

        let delivery = observations.observe(model, tracking: { model in
            _ = model.value
        }) { event, model in
            rendered.set(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: false
                )
            )
        }
        let passes = await delivery.values {
            rendered.value
        }
        var cursor = ObservedValuesCursor(passes)

        #expect(await cursor.next() == ScopePass(kind: .initial, value: 0, isEnabled: false))

        model.value = 1
        #expect(await cursor.next() == ScopePass(kind: .didSet, value: 1, isEnabled: false))
    }

    @Test
    func explicitTrackingRearmsBeforeApplyRuns() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let passes = RenderedValue<[String]>([])
        defer { observations.cancelAll() }

        observations.observe(model, tracking: { model in
            _ = model.value
        }) { event, model in
            passes.set(passes.value + ["\(event.kind):\(model.value)"])
            if event.kind == .initial {
                model.value = 1
            }
        }

        #expect(await waitUntilCondition {
            passes.value == ["initial:0", "didSet:1"]
        })
    }

    @MainActor
    @Test
    func explicitTrackingHonorsActorIsolation() async {
        let model = MainActorCounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(ScopePass(kind: .initial, value: -1, isEnabled: false))
        let trackCalls = RenderedValue(0)
        let applyCalls = RenderedValue(0)
        defer { observations.cancelAll() }

        let delivery = observations.observe(model, tracking: { model in
            MainActor.assertIsolated()
            trackCalls.set(trackCalls.value + 1)
            _ = model.value
        }) { event, model in
            MainActor.assertIsolated()
            applyCalls.set(applyCalls.value + 1)
            rendered.set(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: false
                )
            )
        }
        let passes = await delivery.values {
            MainActor.assertIsolated()
            return rendered.value
        }
        var cursor = ObservedValuesCursor(passes)

        #expect(await cursor.next() == ScopePass(kind: .initial, value: 0, isEnabled: false))

        model.value = 1
        #expect(await cursor.next() == ScopePass(kind: .didSet, value: 1, isEnabled: false))
        #expect(trackCalls.value == 2)
        #expect(applyCalls.value == 2)
    }

    @MainActor
    @Test
    func repeatedObserveFromSameCallSiteReplacesCallbackWithoutDuplicatingPipeline() async {
        let model = MainActorCounterModel()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let first = await installReplacingObservation(
            observations: observations,
            model: model,
            label: "first"
        )
        var firstCursor = ObservedValuesCursor(first.values)
        #expect(await firstCursor.next() == "first:initial:0")

        let second = await installReplacingObservation(
            observations: observations,
            model: model,
            label: "second"
        )
        var secondCursor = ObservedValuesCursor(second.values)

        #expect(first.delivery.isActive == false)
        #expect(first.values.isActive == false)
        #expect(await secondCursor.next() == "second:initial:0")

        model.value = 1
        #expect(await secondCursor.next() == "second:didSet:1")
        #expect(first.values.snapshot() == ["first:initial:0"])
        #expect(second.values.snapshot() == ["second:initial:0", "second:didSet:1"])
    }

    @MainActor
    @Test
    func repeatedObserveFromSameCallSiteRetracksReplacementCallbackBody() async {
        let model = MainActorCounterModel()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let valuePasses = await installReplacingObservation(
            observations: observations,
            model: model,
            readTarget: .value,
            label: "value"
        )
        var valueCursor = ObservedValuesCursor(valuePasses.values)
        #expect(await valueCursor.next() == "value:initial:value:0")

        let enabledPasses = await installReplacingObservation(
            observations: observations,
            model: model,
            readTarget: .isEnabled,
            label: "enabled"
        )
        var enabledCursor = ObservedValuesCursor(enabledPasses.values)
        #expect(valuePasses.delivery.isActive == false)
        #expect(valuePasses.values.isActive == false)
        #expect(await enabledCursor.next() == "enabled:initial:isEnabled:false")

        model.isEnabled = true
        #expect(await enabledCursor.next() == "enabled:didSet:isEnabled:true")

        model.value = 1
        #expect(await enabledCursor.next(timeout: .milliseconds(100)) == nil)
        #expect(
            enabledPasses.values.snapshot() == [
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

        let initialOnlyPasses = await installReplacingObservation(
            observations: observations,
            model: model,
            options: [],
            label: "initial"
        )
        var initialOnlyCursor = ObservedValuesCursor(initialOnlyPasses.values)
        #expect(await initialOnlyCursor.next() == "initial:initial:0")
        #expect(initialOnlyPasses.delivery.isActive == false)
        #expect(initialOnlyPasses.values.isActive == false)

        let didSetPasses = await installReplacingObservation(
            observations: observations,
            model: model,
            options: .didSet,
            label: "did"
        )
        var didSetCursor = ObservedValuesCursor(didSetPasses.values)
        #expect(await didSetCursor.next() == "did:initial:0")

        model.value = 1
        #expect(await didSetCursor.next() == "did:didSet:1")
        #expect(didSetPasses.values.snapshot() == ["did:initial:0", "did:didSet:1"])
    }

    @MainActor
    @Test
    func repeatedObserveFromSameCallSiteWithDifferentOwnerReplacesPipeline() async {
        let firstModel = MainActorCounterModel()
        let secondModel = MainActorCounterModel()
        let observations = ObservationScope()
        defer { observations.cancelAll() }

        let firstPasses = await installReplacingObservation(
            observations: observations,
            model: firstModel,
            label: "first"
        )
        var firstCursor = ObservedValuesCursor(firstPasses.values)
        #expect(await firstCursor.next() == "first:initial:0")

        let secondPasses = await installReplacingObservation(
            observations: observations,
            model: secondModel,
            label: "second"
        )
        var secondCursor = ObservedValuesCursor(secondPasses.values)
        #expect(firstPasses.delivery.isActive == false)
        #expect(firstPasses.values.isActive == false)
        #expect(await secondCursor.next() == "second:initial:0")

        firstModel.value = 1
        #expect(await secondCursor.next(timeout: .milliseconds(100)) == nil)
        #expect(firstPasses.values.snapshot() == ["first:initial:0"])
        #expect(secondPasses.values.snapshot() == ["second:initial:0"])

        secondModel.value = 2
        #expect(await secondCursor.next() == "second:didSet:2")
        #expect(secondPasses.values.snapshot() == ["second:initial:0", "second:didSet:2"])
    }

    @Test
    func observationsFromDifferentCallSitesCoexistAfterStoragePromotion() async {
        let model = CounterModel()
        let observations = ObservationScope()

        let renderedValue = RenderedValue("")
        let valueDelivery = observations.observe(model) { event, model in
            renderedValue.set("value:\(event.kind):\(model.value)")
        }
        let valuePasses = await valueDelivery.values {
            renderedValue.value
        }
        var valueCursor = ObservedValuesCursor(valuePasses)

        let renderedEnabled = RenderedValue("")
        let enabledDelivery = observations.observe(model) { event, model in
            renderedEnabled.set("enabled:\(event.kind):\(model.isEnabled)")
        }
        let enabledPasses = await enabledDelivery.values {
            renderedEnabled.value
        }
        var enabledCursor = ObservedValuesCursor(enabledPasses)

        #expect(await valueCursor.next() == "value:initial:0")
        #expect(await enabledCursor.next() == "enabled:initial:false")

        model.value = 1
        #expect(await valueCursor.next() == "value:didSet:1")
        #expect(await enabledCursor.next(timeout: .milliseconds(100)) == nil)

        model.isEnabled = true
        #expect(await enabledCursor.next() == "enabled:didSet:true")
        #expect(await valueCursor.next(timeout: .milliseconds(100)) == nil)

        observations.cancelAll()
        #expect(valueDelivery.isActive == false)
        #expect(enabledDelivery.isActive == false)
        #expect(valuePasses.isActive == false)
        #expect(enabledPasses.isActive == false)
    }

    @Test
    func cancelAllStopsLaterEventsAndFinishesSamplers() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(ScopePass(kind: .initial, value: -1, isEnabled: false))

        let delivery = observations.observe(model) { event, model in
            rendered.set(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: model.isEnabled
                )
            )
        }
        let passes = await delivery.values {
            rendered.value
        }
        var cursor = ObservedValuesCursor(passes)

        #expect(await cursor.next() == ScopePass(kind: .initial, value: 0, isEnabled: false))
        observations.cancelAll()
        #expect(delivery.isActive == false)
        #expect(passes.isActive == false)

        model.value = 1
        #expect(passes.snapshot() == [ScopePass(kind: .initial, value: 0, isEnabled: false)])
    }

    @Test
    func deliveryCancelStopsObservationAndFinishesSamplers() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(-1)
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { _, model in
            rendered.set(model.value)
        }
        let values = await delivery.values {
            rendered.value
        }
        var cursor = ObservedValuesCursor(values)

        #expect(await cursor.next() == 0)
        delivery.cancel()
        #expect(delivery.isActive == false)
        #expect(values.isActive == false)

        model.value = 1
        #expect(values.snapshot() == [0])
        #expect(rendered.value == 0)
    }

    @Test
    func observedValuesCancelStopsSamplerOnly() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(-1)
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { _, model in
            rendered.set(model.value)
        }
        let firstValues = await delivery.values {
            rendered.value
        }
        var firstCursor = ObservedValuesCursor(firstValues)
        #expect(await firstCursor.next() == 0)

        firstValues.cancel()
        #expect(firstValues.isActive == false)
        #expect(delivery.isActive == true)

        let secondValues = await delivery.values {
            rendered.value
        }
        var secondCursor = ObservedValuesCursor(secondValues)
        #expect(await secondCursor.next() == 0)

        model.value = 1
        #expect(await secondCursor.next() == 1)
        #expect(firstValues.snapshot() == [0])
        #expect(secondValues.snapshot() == [0, 1])
    }

    @Test
    func deliveryFinishAfterCallbackStillSamplesCompletedRender() async {
        let delivery = ObservationDelivery()
        let rendered = RenderedValue(0)
        let values = await delivery.values {
            rendered.value
        }

        #expect(delivery.beginDelivery())
        rendered.set(1)
        let completion = delivery.endDelivery()

        delivery.finish()
        await completion.sampleAndFinish()

        #expect(values.snapshot() == [1])
        #expect(values.isActive == false)
        #expect(delivery.isActive == false)
    }

    @Test
    func deliveryValuesRegisteredDuringCompletedActiveDeliverySampleOnce() async {
        let delivery = ObservationDelivery()
        let rendered = RenderedValue(0)

        #expect(delivery.beginDelivery())
        rendered.set(1)
        let completion = delivery.endDelivery()

        let values = await delivery.values {
            rendered.value
        }
        #expect(values.snapshot() == [1])

        await completion.sampleAndFinish()

        #expect(values.snapshot() == [1])
        delivery.finish()
        #expect(values.isActive == false)
    }

    @Test
    func samplerlessLateValuesSampleSurvivesFinishBeforeImmediateSample() async {
        let delivery = ObservationDelivery()
        let rendered = RenderedValue(0)

        #expect(delivery.beginDelivery())
        rendered.set(1)
        let completion = delivery.endDelivery()
        await completion.sampleAndFinish()

        let values = await delivery._registerValuesForTesting(
            beforeImmediateSample: {
                delivery.finish()
            }
        ) {
            rendered.value
        }

        #expect(values.snapshot() == [1])
        #expect(values.isActive == false)
        #expect(delivery.isActive == false)
    }

    @Test
    func observedValuesCancelRejectsInFlightRecord() {
        let values = ObservedValues<Int>()

        #expect(values.beginDelivery())
        values.cancel()
        values.record(1)
        values.endDelivery()

        #expect(values.snapshot().isEmpty)
        #expect(values.isActive == false)
    }

    @Test
    func observedValuesFinishAllowsInFlightRecordBeforeFinishing() {
        let values = ObservedValues<Int>()

        #expect(values.beginDelivery())
        values.finish()
        values.record(1)
        values.endDelivery()

        #expect(values.snapshot() == [1])
        #expect(values.isActive == false)
    }

    @Test
    func eventCancelCanStopInitialObservationBeforeObserveReturns() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(ObservationEvent.Kind.didSet)
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { event, model in
            _ = model.value
            event.cancel()
            rendered.set(event.kind)
        }
        let kinds = await delivery.values {
            rendered.value
        }
        var cursor = ObservedValuesCursor(kinds)

        #expect(await cursor.next() == .initial)
        #expect(delivery.isActive == false)
        #expect(kinds.isActive == false)

        model.value = 1
        #expect(kinds.snapshot() == [.initial])
    }

    @Test
    func eventCancelDoesNotStopDidSetObservation() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(ScopePass(kind: .initial, value: -1, isEnabled: false))
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { event, model in
            rendered.set(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: false
                )
            )
            if event.kind == .didSet {
                event.cancel()
            }
        }
        let passes = await delivery.values {
            rendered.value
        }
        var cursor = ObservedValuesCursor(passes)

        #expect(await cursor.next() == ScopePass(kind: .initial, value: 0, isEnabled: false))

        model.value = 1

        #expect(await cursor.next() == ScopePass(kind: .didSet, value: 1, isEnabled: false))
        #expect(delivery.isActive == true)

        model.value = 2

        #expect(await cursor.next() == ScopePass(kind: .didSet, value: 2, isEnabled: false))
        #expect(passes.snapshot() == [
            ScopePass(kind: .initial, value: 0, isEnabled: false),
            ScopePass(kind: .didSet, value: 1, isEnabled: false),
            ScopePass(kind: .didSet, value: 2, isEnabled: false),
        ])
    }

    @Test
    func deliveryCancelStopsDidSetObservation() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(ScopePass(kind: .initial, value: -1, isEnabled: false))
        let cancellation = DeliveryCancellationProbe()
        defer { observations.cancelAll() }

        let returnedDelivery = observations.observe(model) { event, model in
            rendered.set(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: false
                )
            )
            if event.kind == .didSet {
                cancellation.cancel()
            }
        }
        cancellation.set(returnedDelivery)
        let passes = await returnedDelivery.values {
            rendered.value
        }
        var cursor = ObservedValuesCursor(passes)

        #expect(await cursor.next() == ScopePass(kind: .initial, value: 0, isEnabled: false))

        model.value = 1

        #expect(await cursor.next() == ScopePass(kind: .didSet, value: 1, isEnabled: false))
        #expect(returnedDelivery.isActive == false)

        model.value = 2
        #expect(passes.snapshot() == [
            ScopePass(kind: .initial, value: 0, isEnabled: false),
            ScopePass(kind: .didSet, value: 1, isEnabled: false),
        ])
    }

    @Test
    func cancelAllDuringSamplerlessDidSetStillAllowsLateSample() async {
        let model = CounterModel()
        let probe = ObservationScopeCancellationProbe()
        let observations = probe.observations
        let rendered = RenderedValue(ScopePass(kind: .initial, value: -1, isEnabled: false))
        let cancelled = RenderedValue(false)
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { event, model in
            rendered.set(
                ScopePass(
                    kind: event.kind,
                    value: model.value,
                    isEnabled: false
                )
            )
            if event.kind == .didSet {
                probe.cancelAll()
                cancelled.set(true)
            }
        }

        model.value = 1

        #expect(await waitUntilCondition {
            rendered.value == ScopePass(kind: .didSet, value: 1, isEnabled: false)
                && cancelled.value
        })
        #expect(delivery.isActive == false)
        #expect(await waitUntilCondition {
            delivery._isIdleAfterCompletedDeliveryForTesting
        })

        let values = await delivery.values {
            rendered.value
        }
        #expect(values.snapshot() == [ScopePass(kind: .didSet, value: 1, isEnabled: false)])
        #expect(values.isActive == false)
    }

    @Test
    func nativeScopeSurvivesConcurrentWriteAndReadStress() async {
        let result = await runRandomizedObservationStress(
            iterations: stressIterationCount(local: 20_000, ci: 200),
            seed: stressSeed(default: 0x26_00_00_00_00_00_00_01)
        ) { model, observations, onObserved in
            observations.observe(model) { _, model in
                onObserved(model.value)
            }
        }

        #expect(result.completed == true)
        #expect(result.firstFailure == nil)
    }

    @Test
    func cancelAllDuringInitialCallbackStillSamplesInitialRender() async {
        let model = CounterModel()
        let probe = ObservationScopeCancellationProbe()
        let observations = probe.observations
        let rendered = RenderedValue(ObservationEvent.Kind.didSet)
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { event, model in
            _ = model.value
            rendered.set(event.kind)
            probe.cancelAll()
        }
        let kinds = await delivery.values {
            rendered.value
        }
        var cursor = ObservedValuesCursor(kinds)

        #expect(await cursor.next() == .initial)
        #expect(delivery.isActive == false)
        #expect(kinds.isActive == false)

        model.value = 1
        #expect(kinds.snapshot() == [.initial])
    }

    @Test
    func cancelledSlotDoesNotStartObservation() async {
        let model = CounterModel()
        let delivery = ObservationDelivery()
        let started = RenderedValue(false)
        let slot = ObservationScopeSlot(
            owner: model,
            options: .didSet,
            observationIsolation: nil,
            delivery: delivery,
            pipeline: TypedObservationScopeImplicitTrackingPipeline<CounterModel> { _, _ in
                started.set(true)
            }
        )

        slot.cancel()
        slot.start()

        #expect(started.value == false)
        #expect(delivery.isActive == false)
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
            let rendered = RenderedValue(-1)
            let delivery = observations.observe(model, options: []) { _, model in
                probe.record(model.value)
                rendered.set(model.value)
            }
            let values = await delivery.values {
                rendered.value
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

    @Test
    func ownerDeinitDoesNotCancelScopeOwnedDelivery() async {
        let observations = ObservationScope()
        let weakModel = WeakDeinitProbeModelBox()
        var delivery: ObservationDelivery?

        do {
            let model = DeinitProbeCounterModel {}
            weakModel.model = model
            delivery = observations.observe(model) { _, model in
                _ = model.value
            }
            #expect(delivery?.isActive == true)
            #expect(await waitUntilCondition { weakModel.model != nil })
        }

        #expect(await waitUntilCondition { weakModel.model == nil })
        #expect(delivery?.isActive == true)

        observations.cancelAll()
        #expect(delivery?.isActive == false)
    }

    @MainActor
    @Test
    func deliveryValuesSupportMainActorRenderedValues() async {
        let model = MainActorNonSendablePayloadModel()
        let observations = ObservationScope()
        let rendered = RenderedValue(-1)
        defer { observations.cancelAll() }

        let delivery = observations.observe(model) { _, model in
            MainActor.assertIsolated()
            rendered.set(model.payload.value)
        }
        let values = await delivery.values {
            MainActor.assertIsolated()
            return rendered.value
        }
        var cursor = ObservedValuesCursor(values)

        #expect(await cursor.next() == 0)
        #expect(values.snapshot() == [0])

        model.payload = NonSendablePayload(value: 2)
        #expect(await cursor.next() == 2)
        #expect(values.snapshot() == [0, 2])
    }

    @Test
    func deliveryValuesUseCustomActorIsolationForCallbacksAndSamplers() async {
        let model = CounterModel()
        let probe = CustomActorObservationProbe()

        let observation = await probe.observe(model)
        var cursor = ObservedValuesCursor(observation.values)
        #expect(await cursor.next() == 0)

        model.value = 4
        #expect(await cursor.next() == 4)
        #expect(observation.values.snapshot() == [0, 4])
        await probe.cancelAll()
    }

    @Test
    func deliveryValuesTrackMultiplePassesOnCustomActorOwnedModel() async {
        let probe = CustomActorOwnedObservationProbe()

        let observation = await probe.observe()
        var cursor = ObservedValuesCursor(observation.values)
        #expect(await cursor.next() == 0)

        await probe.setValue(1)
        #expect(await cursor.next() == 1)

        await probe.setValue(2)
        #expect(await cursor.next() == 2)
        #expect(observation.values.snapshot() == [0, 1, 2])
        await probe.cancelAll()
    }

    @Test
    func deliveryValuesHopToExplicitCustomActorIsolation() async {
        let model = CounterModel()
        let observations = ObservationScope()
        let probe = CustomActorObservationProbe()
        let rendered = RenderedValue(-1)
        defer { observations.cancelAll() }

        let delivery = await observations.observe(
            model,
            options: .didSet,
            { _, model in
                probe.assumeIsolated { isolatedProbe in
                    isolatedProbe.preconditionIsolated()
                    rendered.set(model.value)
                }
            },
            isolation: probe
        )
        let values = await delivery.values(isolation: probe) { isolatedProbe in
            isolatedProbe.preconditionIsolated()
            return rendered.value
        }
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

private struct RenderedObservation<Value: Sendable>: Sendable {
    let delivery: ObservationDelivery
    let values: ObservedValues<Value>
}

private final class RenderedValue<Value: Sendable>: @unchecked Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) {
        storage = Mutex(value)
    }

    var value: Value {
        storage.withLock { $0 }
    }

    func set(_ value: Value) {
        storage.withLock { storedValue in
            storedValue = value
        }
    }
}

private final class DeliveryCancellationProbe: @unchecked Sendable {
    private let storage = Mutex<ObservationDelivery?>(nil)

    func set(_ delivery: ObservationDelivery) {
        storage.withLock { storedDelivery in
            storedDelivery = delivery
        }
    }

    func cancel() {
        let delivery = storage.withLock { storedDelivery in
            storedDelivery
        }
        delivery?.cancel()
    }
}

@MainActor
private final class MainActorSampleProbe: @unchecked Sendable {
    private var count = 0

    func next() -> Int {
        MainActor.assertIsolated()
        count += 1
        return count
    }
}

@discardableResult
private func installReplacingObservation(
    observations: ObservationScope,
    model: CounterModel,
    options: ObservationOptions = .didSet,
    label: String
) async -> RenderedObservation<String> {
    let rendered = RenderedValue("")
    let delivery = observations.observe(model, options: options) { event, model in
        rendered.set("\(label):\(event.kind):\(model.value)")
    }
    let values = await delivery.values {
        rendered.value
    }
    return RenderedObservation(delivery: delivery, values: values)
}

@MainActor
@discardableResult
private func installReplacingObservation(
    observations: ObservationScope,
    model: MainActorCounterModel,
    options: ObservationOptions = .didSet,
    label: String
) async -> RenderedObservation<String> {
    let rendered = RenderedValue("")
    let delivery = observations.observe(model, options: options) { event, model in
        MainActor.assertIsolated()
        rendered.set("\(label):\(event.kind):\(model.value)")
    }
    let values = await delivery.values {
        MainActor.assertIsolated()
        return rendered.value
    }
    return RenderedObservation(delivery: delivery, values: values)
}

@discardableResult
private func installReplacingObservation(
    observations: ObservationScope,
    model: CounterModel,
    readTarget: ReplacementReadTarget,
    label: String
) async -> RenderedObservation<String> {
    let rendered = RenderedValue("")
    let delivery = observations.observe(model) { event, model in
        switch readTarget {
        case .value:
            rendered.set("\(label):\(event.kind):value:\(model.value)")
        case .isEnabled:
            rendered.set("\(label):\(event.kind):isEnabled:\(model.isEnabled)")
        }
    }
    let values = await delivery.values {
        rendered.value
    }
    return RenderedObservation(delivery: delivery, values: values)
}

@MainActor
@discardableResult
private func installReplacingObservation(
    observations: ObservationScope,
    model: MainActorCounterModel,
    readTarget: ReplacementReadTarget,
    label: String
) async -> RenderedObservation<String> {
    let rendered = RenderedValue("")
    let delivery = observations.observe(model) { event, model in
        MainActor.assertIsolated()
        switch readTarget {
        case .value:
            rendered.set("\(label):\(event.kind):value:\(model.value)")
        case .isEnabled:
            rendered.set("\(label):\(event.kind):isEnabled:\(model.isEnabled)")
        }
    }
    let values = await delivery.values {
        MainActor.assertIsolated()
        return rendered.value
    }
    return RenderedObservation(delivery: delivery, values: values)
}

private actor CustomActorObservationProbe {
    private let observations = ObservationScope()
    private let rendered = RenderedValue(-1)

    func observe(_ model: CounterModel) async -> RenderedObservation<Int> {
        let delivery = observations.observe(model) { _, model in
            self.preconditionIsolated()
            self.rendered.set(model.value)
        }
        let values = await delivery.values {
            self.preconditionIsolated()
            return self.rendered.value
        }
        return RenderedObservation(delivery: delivery, values: values)
    }

    func cancelAll() {
        observations.cancelAll()
    }
}

private actor CustomActorOwnedObservationProbe {
    private let observations = ObservationScope()
    private let model = CounterModel()
    private let rendered = RenderedValue(-1)

    func observe() async -> RenderedObservation<Int> {
        let delivery = observations.observe(model) { _, model in
            self.preconditionIsolated()
            self.rendered.set(model.value)
        }
        let values = await delivery.values {
            self.preconditionIsolated()
            return self.rendered.value
        }
        return RenderedObservation(delivery: delivery, values: values)
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
