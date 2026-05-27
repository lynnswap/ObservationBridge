import Foundation
import Synchronization

/// Records values sampled after owner-bound observation delivery.
///
/// `ObservedValues` is intended for tests that need to synchronize with
/// `ObservationScope.observe` delivery without sleeping. Instances are produced
/// by ``ObservationDelivery/values(_:)``.
public final class ObservedValues<Value: Sendable>: Sendable {
    private struct Waiter: Sendable {
        let predicate: @Sendable (Value) -> Bool
        let continuation: CheckedContinuation<Value?, Never>
        var timeoutTask: Task<Void, Never>?
    }

    private struct WaiterResolution: Sendable {
        let continuation: CheckedContinuation<Value?, Never>
        let timeoutTask: Task<Void, Never>?
    }

    private enum WaitSetup {
        case immediate(Value?)
        case waiting(UInt64)
    }

    private struct State: Sendable {
        var values: [Value] = []
        var isActive = true
        var activeDeliveries = 0
        var recordsInFlightAfterFinish = false
        var shouldFinishAfterDeliveries = false
        var waiters: [UInt64: Waiter] = [:]
        var nextWaiterID: UInt64 = 0
        var cancelOperation: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    /// The most recently recorded value, or `nil` if the observation has not
    /// delivered any values yet.
    public var latestValue: Value? {
        state.withLock { state in
            state.values.last
        }
    }

    /// Whether this value recorder is still active.
    public var isActive: Bool {
        state.withLock { state in
            state.isActive
        }
    }

    init() {}

    deinit {
        cancel()
    }

    /// Returns all values recorded so far.
    public func snapshot() -> [Value] {
        state.withLock { state in
            state.values
        }
    }

    /// Waits until `expected` has been recorded.
    ///
    /// The timeout is only a test guard. It does not affect observation delivery
    /// or stream rate limiting.
    public func waitUntilValue(
        _ expected: Value,
        timeout: Duration = .seconds(5)
    ) async -> Bool where Value: Equatable {
        await waitUntil(timeout: timeout) { value in
            value == expected
        } != nil
    }

    /// Waits until a recorded value satisfies `predicate`.
    ///
    /// If a matching value was already recorded, this returns it immediately.
    /// Returns `nil` when the timeout elapses or the observation finishes first.
    public func waitUntil(
        timeout: Duration = .seconds(5),
        _ predicate: @escaping @Sendable (Value) -> Bool
    ) async -> Value? {
        await waitUntil(
            timeout: timeout,
            matchingExistingValuesFrom: 0,
            predicate
        )
    }

    func waitUntilNewValue(
        after existingCount: Int,
        timeout: Duration = .seconds(5),
        _ predicate: @escaping @Sendable (Value) -> Bool = { _ in true }
    ) async -> Value? {
        await waitUntil(
            timeout: timeout,
            matchingExistingValuesFrom: existingCount,
            predicate
        )
    }

    private func waitUntil(
        timeout: Duration,
        matchingExistingValuesFrom startIndex: Int,
        _ predicate: @escaping @Sendable (Value) -> Bool
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            let setup = state.withLock { state -> WaitSetup in
                let firstExistingIndex = min(max(startIndex, 0), state.values.count)
                if let value = state.values[firstExistingIndex...].first(where: predicate) {
                    return .immediate(value)
                }

                guard state.isActive else {
                    return .immediate(nil)
                }

                let id = state.nextWaiterID
                state.nextWaiterID &+= 1
                state.waiters[id] = Waiter(predicate: predicate, continuation: continuation)
                return .waiting(id)
            }

            switch setup {
            case .immediate(let value):
                continuation.resume(returning: value)
            case .waiting(let id):
                let timeoutTask = Task { [self] in
                    try? await Task.sleep(for: timeout)
                    resolveWaiter(id: id, value: nil)
                }
                if setTimeoutTask(timeoutTask, forWaiter: id) {
                    timeoutTask.cancel()
                }
            }
        }
    }

    /// Stops this value recorder and wakes any pending waiters.
    public func cancel() {
        let result = deactivate(takeCancelOperation: true, finishInFlightDeliveries: false)
        result.cancelOperation?()
        resume(result.waiters, returning: nil)
    }

    func setCancelOperation(_ operation: @escaping @Sendable () -> Void) {
        let shouldRunImmediately = state.withLock { state in
            guard state.isActive else {
                return true
            }

            state.cancelOperation = operation
            return false
        }

        if shouldRunImmediately {
            operation()
        }
    }

    func record(_ value: Value) {
        let resolutions = state.withLock { state -> [WaiterResolution] in
            guard state.isActive || (state.activeDeliveries > 0 && state.recordsInFlightAfterFinish) else {
                return []
            }

            state.values.append(value)

            let matchingIDs = state.waiters.compactMap { id, waiter in
                waiter.predicate(value) ? id : nil
            }
            var resolutions: [WaiterResolution] = []
            for id in matchingIDs {
                if let waiter = state.waiters.removeValue(forKey: id) {
                    resolutions.append(
                        WaiterResolution(
                            continuation: waiter.continuation,
                            timeoutTask: waiter.timeoutTask
                        )
                    )
                }
            }
            return resolutions
        }

        resume(resolutions, returning: value)
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

    func endDelivery() {
        let waiters = state.withLock { state -> [WaiterResolution] in
            guard state.activeDeliveries > 0 else {
                return []
            }

            state.activeDeliveries -= 1
            guard state.activeDeliveries == 0, state.shouldFinishAfterDeliveries else {
                return []
            }

            state.shouldFinishAfterDeliveries = false
            let waiters = state.waiters.map { waiter in
                WaiterResolution(
                    continuation: waiter.value.continuation,
                    timeoutTask: waiter.value.timeoutTask
                )
            }
            state.waiters.removeAll(keepingCapacity: true)
            return waiters
        }

        resume(waiters, returning: nil)
    }

    func finish() {
        let result = deactivate(takeCancelOperation: false, finishInFlightDeliveries: true)
        resume(result.waiters, returning: nil)
    }

    private func resolveWaiter(id: UInt64, value: Value?) {
        let waiter = state.withLock { state in
            state.waiters.removeValue(forKey: id)
        }

        waiter?.timeoutTask?.cancel()
        waiter?.continuation.resume(returning: value)
    }

    private func setTimeoutTask(_ task: Task<Void, Never>, forWaiter id: UInt64) -> Bool {
        state.withLock { state in
            guard state.waiters[id] != nil else {
                return true
            }

            state.waiters[id]?.timeoutTask = task
            return false
        }
    }

    private func deactivate(
        takeCancelOperation: Bool,
        finishInFlightDeliveries: Bool
    ) -> (cancelOperation: (@Sendable () -> Void)?, waiters: [WaiterResolution]) {
        state.withLock { state in
            guard state.isActive || !state.waiters.isEmpty || state.cancelOperation != nil else {
                return (nil, [])
            }

            state.isActive = false
            let cancelOperation = takeCancelOperation ? state.cancelOperation : nil
            state.cancelOperation = nil
            guard state.activeDeliveries == 0 else {
                state.recordsInFlightAfterFinish = finishInFlightDeliveries
                if !finishInFlightDeliveries {
                    let waiters = state.waiters.map { waiter in
                        WaiterResolution(
                            continuation: waiter.value.continuation,
                            timeoutTask: waiter.value.timeoutTask
                        )
                    }
                    state.waiters.removeAll(keepingCapacity: true)
                    return (cancelOperation, waiters)
                }
                state.shouldFinishAfterDeliveries = true
                return (cancelOperation, [])
            }

            let waiters = state.waiters.map { waiter in
                WaiterResolution(
                    continuation: waiter.value.continuation,
                    timeoutTask: waiter.value.timeoutTask
                )
            }
            state.waiters.removeAll(keepingCapacity: true)
            return (cancelOperation, waiters)
        }
    }

    private func resume(
        _ resolutions: [WaiterResolution],
        returning value: Value?
    ) {
        for resolution in resolutions {
            resolution.timeoutTask?.cancel()
            resolution.continuation.resume(returning: value)
        }
    }
}
