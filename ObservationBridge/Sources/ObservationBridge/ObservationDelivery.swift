import Synchronization

/// Represents an owner-bound observation delivery pipeline.
///
/// `ObservationDelivery` is returned from `ObservationScope.observe(...)`.
/// Tests can attach value samplers with ``values(_:)`` to wait for
/// state rendered by the production callback after each delivery completes.
public final class ObservationDelivery: Sendable {
    private struct State: Sendable {
        var isActive = true
        var hasDelivered = false
        var activeDeliveries = 0
        var deliveryGeneration: UInt64 = 0
        var completedDeliveriesAwaitingSampling = 0
        var shouldFinishAfterDeliveries = false
        var samplers: [UInt64: SamplerRegistration] = [:]
        var nextSamplerID: UInt64 = 0
        weak var slot: ObservationScopeSlot?
    }

    private struct SamplerRegistration: Sendable {
        let sampler: any ObservationDeliverySampler
        var lastSampledGeneration: UInt64
    }

    private let state = Mutex(State())

    /// Whether the backing observation is still active.
    public var isActive: Bool {
        state.withLock { state in
            state.isActive
        }
    }

    init() {}

    /// Cancels the backing observation.
    public func cancel() {
        let slot = state.withLock { state in
            guard state.isActive else {
                return nil as ObservationScopeSlot?
            }

            return state.slot
        }

        if let slot {
            slot.cancel()
        } else {
            finish()
        }
    }

    /// Samples a value after each completed observation delivery.
    ///
    /// If the observation has already delivered at least once, this samples the
    /// current rendered state before returning. Previously delivered values are
    /// not replayed.
    public func values<Value: Sendable>(
        @_inheritActorContext _ sample: @escaping @isolated(any) @Sendable () -> Value
    ) async -> ObservedValues<Value> {
        let values = ObservedValues<Value>()
        let sampler = ObservationDeliverySamplerBox(sample: sample, values: values)
        return await register(values: values, sampler: sampler)
    }

    /// Samples a value on an explicit actor after each completed observation delivery.
    public func values<SampleIsolation: Actor, Value: Sendable>(
        isolation actor: isolated SampleIsolation,
        _ sample: @escaping @Sendable (isolated SampleIsolation) -> Value
    ) async -> ObservedValues<Value> {
        let values = ObservedValues<Value>()
        let sampler = ObservationDeliveryActorSamplerBox(
            actor: actor,
            sample: sample,
            values: values
        )
        return await register(values: values, sampler: sampler)
    }

    private func register<Value: Sendable>(
        values: ObservedValues<Value>,
        sampler: any ObservationDeliverySampler
    ) async -> ObservedValues<Value> {
        let registration = state.withLock { state -> (id: UInt64?, sampleImmediately: Bool, finishAfterSample: Bool) in
            let shouldSampleCurrentDelivery =
                state.hasDelivered
                    && (state.activeDeliveries == 0 || state.completedDeliveriesAwaitingSampling > 0)

            guard state.isActive else {
                return (nil, shouldSampleCurrentDelivery, true)
            }

            let id = state.nextSamplerID
            state.nextSamplerID &+= 1
            state.samplers[id] = SamplerRegistration(
                sampler: sampler,
                lastSampledGeneration: state.deliveryGeneration
            )
            if shouldSampleCurrentDelivery {
                state.samplers[id]?.lastSampledGeneration = state.deliveryGeneration
            }
            return (id, shouldSampleCurrentDelivery, false)
        }

        if let id = registration.id {
            values.setCancelOperation { [weak self] in
                self?.removeSampler(id: id)
            }
        }

        if registration.sampleImmediately {
            await sampler.sample()
            if registration.finishAfterSample {
                values.finish()
            }
        } else if registration.finishAfterSample {
            values.finish()
        }

        return values
    }

    func bind(to slot: ObservationScopeSlot) {
        let shouldCancelImmediately = state.withLock { state in
            guard state.isActive else {
                return true
            }

            state.slot = slot
            return false
        }

        if shouldCancelImmediately {
            slot.cancel()
        }
    }

    func beginDelivery() -> Bool {
        state.withLock { state in
            guard state.isActive else {
                return false
            }

            state.activeDeliveries += 1
            return true
        }
    }

    func endDelivery() -> ObservationDeliveryCompletion {
        let delivery = state.withLock { state -> (isActive: Bool, generation: UInt64) in
            guard state.activeDeliveries > 0 else {
                return (false, state.deliveryGeneration)
            }

            state.hasDelivered = true
            state.deliveryGeneration &+= 1
            state.completedDeliveriesAwaitingSampling += 1
            return (true, state.deliveryGeneration)
        }

        return ObservationDeliveryCompletion(
            delivery: self,
            isActive: delivery.isActive,
            generation: delivery.generation
        )
    }

    func discardDelivery() {
        state.withLock { state in
            guard state.activeDeliveries > 0 else {
                return
            }

            state.activeDeliveries -= 1
        }

        finishSamplersIfInactiveAndIdle()
    }

    func finish() {
        let samplers = state.withLock { state -> [any ObservationDeliverySampler] in
            guard state.isActive || !state.samplers.isEmpty else {
                return []
            }

            state.isActive = false
            state.slot = nil

            guard state.activeDeliveries == 0 else {
                state.shouldFinishAfterDeliveries = true
                return []
            }

            let samplers = state.samplers.values.map(\.sampler)
            state.samplers.removeAll(keepingCapacity: true)
            state.shouldFinishAfterDeliveries = false
            return samplers
        }

        finish(samplers)
    }

    private func removeSampler(id: UInt64) {
        state.withLock { state in
            state.samplers[id] = nil
        }
    }

    fileprivate func sampleActiveDeliveryAndFinish(generation: UInt64) async {
        let samplers = state.withLock { state -> [any ObservationDeliverySampler] in
            guard state.activeDeliveries > 0, state.completedDeliveriesAwaitingSampling > 0 else {
                return []
            }

            var samplers: [any ObservationDeliverySampler] = []
            for id in state.samplers.keys {
                guard let registration = state.samplers[id], registration.lastSampledGeneration < generation else {
                    continue
                }

                state.samplers[id]?.lastSampledGeneration = generation
                samplers.append(registration.sampler)
            }
            return samplers
        }

        for sampler in samplers {
            await sampler.sample()
        }

        finishActiveDelivery()
    }

    fileprivate func finishActiveDelivery() {
        state.withLock { state in
            guard state.activeDeliveries > 0 else {
                return
            }

            if state.completedDeliveriesAwaitingSampling > 0 {
                state.completedDeliveriesAwaitingSampling -= 1
            }
            state.activeDeliveries -= 1
        }

        finishSamplersIfInactiveAndIdle()
    }

    private func finishSamplersIfInactiveAndIdle() {
        finish(
            state.withLock { state in
                takeSamplersIfInactiveAndIdle(&state)
            }
        )
    }

    private func finish(_ samplers: [any ObservationDeliverySampler]) {
        for sampler in samplers {
            sampler.finish()
        }
    }

    private func takeSamplersIfInactiveAndIdle(
        _ state: inout State
    ) -> [any ObservationDeliverySampler] {
        guard !state.isActive, state.activeDeliveries == 0, state.shouldFinishAfterDeliveries else {
            return []
        }

        state.shouldFinishAfterDeliveries = false
        let samplers = state.samplers.values.map(\.sampler)
        state.samplers.removeAll(keepingCapacity: true)
        return samplers
    }
}

struct ObservationDeliveryCompletion: Sendable {
    private weak var delivery: ObservationDelivery?
    private let isActive: Bool
    private let generation: UInt64

    fileprivate init(
        delivery: ObservationDelivery,
        isActive: Bool,
        generation: UInt64
    ) {
        self.delivery = delivery
        self.isActive = isActive
        self.generation = generation
    }

    func sampleAndFinish() async {
        guard isActive else {
            return
        }

        await delivery?.sampleActiveDeliveryAndFinish(generation: generation)
    }

    func finishWithoutSampling() {
        guard isActive else {
            return
        }

        delivery?.finishActiveDelivery()
    }
}

private protocol ObservationDeliverySampler: AnyObject, Sendable {
    func sample() async
    func finish()
}

private final class ObservationDeliverySamplerBox<Value: Sendable>: ObservationDeliverySampler, @unchecked Sendable {
    private let sampleClosure: @isolated(any) @Sendable () -> Value
    private let values: ObservedValues<Value>

    init(
        sample: @escaping @isolated(any) @Sendable () -> Value,
        values: ObservedValues<Value>
    ) {
        self.sampleClosure = sample
        self.values = values
    }

    func sample() async {
        guard values.beginDelivery() else {
            return
        }
        defer {
            values.endDelivery()
        }

        let value = await sampleClosure()
        values.record(value)
    }

    func finish() {
        values.finish()
    }
}

private final class ObservationDeliveryActorSamplerBox<SampleIsolation: Actor, Value: Sendable>: ObservationDeliverySampler, @unchecked Sendable {
    private let actor: SampleIsolation
    private let sampleClosure: @Sendable (isolated SampleIsolation) -> Value
    private let values: ObservedValues<Value>

    init(
        actor: isolated SampleIsolation,
        sample: @escaping @Sendable (isolated SampleIsolation) -> Value,
        values: ObservedValues<Value>
    ) {
        self.actor = actor
        self.sampleClosure = sample
        self.values = values
    }

    func sample() async {
        guard values.beginDelivery() else {
            return
        }
        defer {
            values.endDelivery()
        }

        let value = await sampleClosure(actor)
        values.record(value)
    }

    func finish() {
        values.finish()
    }
}
