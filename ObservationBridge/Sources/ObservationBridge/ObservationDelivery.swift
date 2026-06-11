import Foundation
import Observation
import Synchronization

extension PortableObservationTracking {
    /// A token that keeps a portable continuous observation alive.
    ///
    /// Cancel the token, or let it deinitialize, to stop the observation.
    /// Tests can attach value samplers with ``values(_:)`` to wait for state
    /// rendered by the production callback after each delivery completes.
    public struct Token: Sendable {
        private final class Storage: @unchecked Sendable {
            private let cancelOperation: @Sendable () -> Void
            let delivery: ObservationDelivery

            init(
                delivery: ObservationDelivery,
                cancelOperation: @escaping @Sendable () -> Void
            ) {
                self.delivery = delivery
                self.cancelOperation = cancelOperation
            }

            deinit {
                cancel()
            }

            func cancel() {
                cancelOperation()
            }
        }

        private let storage: Storage

        /// Whether the backing observation is still active.
        public var isActive: Bool {
            storage.delivery.isActive
        }

        var _isIdleAfterCompletedDeliveryForTesting: Bool {
            storage.delivery._isIdleAfterCompletedDeliveryForTesting
        }

        init(slot: ObservationScopeSlot, delivery: ObservationDelivery) {
            storage = Storage(delivery: delivery) {
                slot.cancel()
            }
        }

        #if compiler(>=6.4)
        @available(anyAppleOS 27.0, *)
        init(
            nativeContinuousCancellation: NativeContinuousObservationCancellation,
            delivery: ObservationDelivery
        ) {
            storage = Storage(delivery: delivery) {
                nativeContinuousCancellation.cancel()
                delivery.finish()
            }
        }
        #endif

        /// Cancels the backing observation.
        public func cancel() {
            storage.cancel()
        }

        /// Samples a value after each completed observation delivery.
        ///
        /// If the observation has already delivered at least once, this samples the
        /// current rendered state before returning. Previously delivered values are
        /// not replayed.
        public func values<Value: Sendable>(
            @_inheritActorContext _ sample: @escaping @isolated(any) @Sendable () -> Value
        ) async -> ObservedValues<Value> {
            await storage.delivery.values(sample)
        }

        /// Samples a value on an explicit actor after each completed observation delivery.
        public func values<SampleIsolation: Actor, Value: Sendable>(
            isolation actor: isolated SampleIsolation,
            _ sample: @escaping @Sendable (isolated SampleIsolation) -> Value
        ) async -> ObservedValues<Value> {
            await storage.delivery.values(isolation: actor, sample)
        }
    }
}

#if compiler(>=6.4)
@available(anyAppleOS 27.0, *)
private struct NativeContinuousObservationTokenStorage: ~Copyable {
    var token: ObservationTracking.Token

    init(_ token: consuming ObservationTracking.Token) {
        self.token = token
    }
}

@available(anyAppleOS 27.0, *)
private func makeNativeContinuousObservationTokenStorage(
    _ token: consuming ObservationTracking.Token
) -> UnsafeMutableRawPointer {
    let pointer = UnsafeMutablePointer<NativeContinuousObservationTokenStorage>.allocate(capacity: 1)
    pointer.initialize(to: NativeContinuousObservationTokenStorage(token))
    return UnsafeMutableRawPointer(pointer)
}

@available(anyAppleOS 27.0, *)
private func releaseNativeContinuousObservationTokenStorage(
    _ rawPointer: UnsafeMutableRawPointer
) {
    let pointer = rawPointer.assumingMemoryBound(to: NativeContinuousObservationTokenStorage.self)
    pointer.deinitialize(count: 1)
    pointer.deallocate()
}

@available(anyAppleOS 27.0, *)
final class NativeContinuousObservationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var tokenStorage: UnsafeMutableRawPointer?
    private var task: Task<Void, Never>?
    private var isCancelled = false

    deinit {
        cancel()
    }

    func install(_ token: consuming ObservationTracking.Token) {
        let tokenStorage = makeNativeContinuousObservationTokenStorage(token)

        lock.lock()
        if isCancelled {
            lock.unlock()
            releaseNativeContinuousObservationTokenStorage(tokenStorage)
            return
        }

        let oldTokenStorage = self.tokenStorage
        self.tokenStorage = tokenStorage
        task = nil
        lock.unlock()
        if let oldTokenStorage {
            releaseNativeContinuousObservationTokenStorage(oldTokenStorage)
        }
    }

    func installTask(_ task: Task<Void, Never>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            task.cancel()
            return
        }

        let taskToCancel = self.task
        self.task = task
        lock.unlock()
        taskToCancel?.cancel()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let tokenStorageToRelease = tokenStorage
        tokenStorage = nil
        let taskToCancel = task
        task = nil
        lock.unlock()
        if let tokenStorageToRelease {
            releaseNativeContinuousObservationTokenStorage(tokenStorageToRelease)
        }
        taskToCancel?.cancel()
    }
}
#endif

final class ObservationDelivery: Sendable {
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

    private struct Registration: Sendable {
        let id: UInt64?
        let sampleImmediately: Bool
        let finishAfterSample: Bool
        let finishDeliveryAfterSample: Bool
    }

    private let state = Mutex(State())

    /// Whether the backing observation is still active.
    public var isActive: Bool {
        state.withLock { state in
            state.isActive
        }
    }

    var _isIdleAfterCompletedDeliveryForTesting: Bool {
        state.withLock { state in
            state.hasDelivered
                && state.activeDeliveries == 0
                && state.completedDeliveriesAwaitingSampling == 0
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
        sampler: any ObservationDeliverySampler,
        beforeImmediateSample: (@Sendable () -> Void)? = nil
    ) async -> ObservedValues<Value> {
        let registration = state.withLock { state -> Registration in
            let shouldSampleCurrentDelivery =
                state.hasDelivered
                    && (state.activeDeliveries == 0 || state.completedDeliveriesAwaitingSampling > 0)

            guard state.isActive else {
                return Registration(
                    id: nil,
                    sampleImmediately: shouldSampleCurrentDelivery,
                    finishAfterSample: true,
                    finishDeliveryAfterSample: false
                )
            }

            let id = state.nextSamplerID
            state.nextSamplerID &+= 1
            state.samplers[id] = SamplerRegistration(
                sampler: sampler,
                lastSampledGeneration: state.deliveryGeneration
            )
            if shouldSampleCurrentDelivery {
                state.samplers[id]?.lastSampledGeneration = state.deliveryGeneration
                state.activeDeliveries += 1
                state.completedDeliveriesAwaitingSampling += 1
            }
            return Registration(
                id: id,
                sampleImmediately: shouldSampleCurrentDelivery,
                finishAfterSample: false,
                finishDeliveryAfterSample: shouldSampleCurrentDelivery
            )
        }

        if let id = registration.id {
            values.setCancelOperation { [weak self] in
                self?.removeSampler(id: id)
            }
        }

        if registration.sampleImmediately {
            beforeImmediateSample?()
            await sampler.sample()
            if registration.finishDeliveryAfterSample {
                finishActiveDelivery()
            }
            if registration.finishAfterSample {
                values.finish()
            }
        } else if registration.finishAfterSample {
            values.finish()
        }

        return values
    }

    func _registerValuesForTesting<Value: Sendable>(
        beforeImmediateSample: @escaping @Sendable () -> Void,
        _ sample: @escaping @isolated(any) @Sendable () -> Value
    ) async -> ObservedValues<Value> {
        let values = ObservedValues<Value>()
        let sampler = ObservationDeliverySamplerBox(sample: sample, values: values)
        return await register(
            values: values,
            sampler: sampler,
            beforeImmediateSample: beforeImmediateSample
        )
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
        let delivery = state.withLock { state -> (isActive: Bool, generation: UInt64, needsSampling: Bool) in
            guard state.activeDeliveries > 0 else {
                return (false, state.deliveryGeneration, false)
            }

            state.hasDelivered = true
            state.deliveryGeneration &+= 1
            let generation = state.deliveryGeneration

            guard !state.samplers.isEmpty || state.completedDeliveriesAwaitingSampling > 0 else {
                state.activeDeliveries -= 1
                return (true, generation, false)
            }

            state.completedDeliveriesAwaitingSampling += 1
            return (true, generation, true)
        }

        if delivery.isActive, !delivery.needsSampling {
            finishSamplersIfInactiveAndIdle()
        }

        return ObservationDeliveryCompletion(
            delivery: self,
            isActive: delivery.isActive,
            generation: delivery.generation,
            needsSampling: delivery.needsSampling
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

final class ObservationDeliveryCompletionQueue: Sendable {
    private struct State: Sendable {
        var completions: [ObservationDeliveryCompletion] = []
        var isDraining = false
    }

    private let state = Mutex(State())

    func enqueue(_ completion: ObservationDeliveryCompletion) {
        let shouldStartDrain = state.withLock { state in
            state.completions.append(completion)
            guard !state.isDraining else {
                return false
            }

            state.isDraining = true
            return true
        }

        if shouldStartDrain {
            Task {
                await drain()
            }
        }
    }

    private func nextCompletion() -> ObservationDeliveryCompletion? {
        state.withLock { state in
            guard !state.completions.isEmpty else {
                state.isDraining = false
                return nil
            }

            return state.completions.removeFirst()
        }
    }

    private func drain() async {
        while let completion = nextCompletion() {
            await completion.sampleAndFinish()
        }
    }
}

struct ObservationDeliveryCompletion: Sendable {
    private weak var delivery: ObservationDelivery?
    private let isActive: Bool
    private let generation: UInt64
    private let needsSampling: Bool

    fileprivate init(
        delivery: ObservationDelivery,
        isActive: Bool,
        generation: UInt64,
        needsSampling: Bool
    ) {
        self.delivery = delivery
        self.isActive = isActive
        self.generation = generation
        self.needsSampling = needsSampling
    }

    func sampleAndFinish() async {
        guard isActive, needsSampling else {
            return
        }

        await delivery?.sampleActiveDeliveryAndFinish(generation: generation)
    }

    func finishWithoutSampling() {
        guard isActive, needsSampling else {
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
