import Foundation
import Synchronization
@testable import ObservationBridge

actor ValueQueue<Value: Sendable> {
    private var buffered: [Value] = []
    private var waiters: [UUID: CheckedContinuation<Value?, Never>] = [:]

    func push(_ value: Value) {
        if let key = waiters.keys.first, let waiter = waiters.removeValue(forKey: key) {
            waiter.resume(returning: value)
            return
        }
        buffered.append(value)
    }

    func next() async -> Value? {
        if !buffered.isEmpty {
            return buffered.removeFirst()
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: id)
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else {
            return
        }
        waiter.resume(returning: nil)
    }
}

actor CallbackIsolationActor {
    func handle(_ value: sending Int, queue: ValueQueue<Int>) async {
        await queue.push(value)
    }
}

@globalActor
actor AlternateGlobalActor {
    static let shared = AlternateGlobalActor()
}

final class TestDebounceClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Swift.Duration

    private struct SleepWaiter {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct SuspensionWaiter {
        let minimumSleepers: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var now: Instant
        var sleepers: [UInt64: SleepWaiter] = [:]
        var nextSleepToken: UInt64 = 0
        var suspensionWaiters: [UInt64: SuspensionWaiter] = [:]
        var nextSuspensionToken: UInt64 = 0
    }

    private let state: Mutex<State>

    var now: Instant {
        state.withLock { $0.now }
    }

    var minimumResolution: Duration {
        .nanoseconds(1)
    }

    init(now: Instant = ContinuousClock().now) {
        state = Mutex(State(now: now))
    }

    func sleep(until deadline: Instant, tolerance _: Duration? = nil) async throws {
        if deadline <= now {
            return
        }
        try Task.checkCancellation()

        let sleepToken = state.withLock { state in
            let token = state.nextSleepToken
            state.nextSleepToken &+= 1
            return token
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let suspensionContinuations: [CheckedContinuation<Void, Never>] = state.withLock { state in
                    if deadline <= state.now {
                        continuation.resume(returning: ())
                        return []
                    }

                    state.sleepers[sleepToken] = SleepWaiter(
                        deadline: deadline,
                        continuation: continuation
                    )
                    return Self.popReadySuspensionWaiters(state: &state)
                }
                for suspensionContinuation in suspensionContinuations {
                    suspensionContinuation.resume()
                }
            }
        } onCancel: {
            let cancellationContinuation: CheckedContinuation<Void, Error>? = state.withLock { state in
                state.sleepers.removeValue(forKey: sleepToken)?.continuation
            }
            cancellationContinuation?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        precondition(duration >= .zero, "duration must be non-negative")

        let readyContinuations: [CheckedContinuation<Void, Error>] = state.withLock { state in
            state.now = state.now.advanced(by: duration)

            let readySleepTokens = state.sleepers.compactMap { token, waiter in
                waiter.deadline <= state.now ? token : nil
            }

            return readySleepTokens.compactMap { token in
                state.sleepers.removeValue(forKey: token)?.continuation
            }
        }

        for continuation in readyContinuations {
            continuation.resume(returning: ())
        }
    }

    func sleep(untilSuspendedBy minimumSleepers: Int = 1) async {
        precondition(minimumSleepers > 0, "minimumSleepers must be positive")
        let suspensionToken = state.withLock { state in
            let token = state.nextSuspensionToken
            state.nextSuspensionToken &+= 1
            return token
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResumeImmediately = state.withLock { state in
                    if state.sleepers.count >= minimumSleepers {
                        return true
                    }

                    state.suspensionWaiters[suspensionToken] = SuspensionWaiter(
                        minimumSleepers: minimumSleepers,
                        continuation: continuation
                    )
                    return false
                }

                if shouldResumeImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            let cancellationContinuation = state.withLock { state in
                state.suspensionWaiters.removeValue(forKey: suspensionToken)?.continuation
            }
            cancellationContinuation?.resume()
        }
    }

    private static func popReadySuspensionWaiters(state: inout State) -> [CheckedContinuation<Void, Never>] {
        let readyTokens = state.suspensionWaiters.compactMap { token, waiter in
            state.sleepers.count >= waiter.minimumSleepers ? token : nil
        }

        return readyTokens.compactMap { token in
            state.suspensionWaiters.removeValue(forKey: token)?.continuation
        }
    }
}

struct DescriptorValueClock: Clock, Hashable, Sendable {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Swift.Duration

    let id: Int

    var now: Instant {
        ContinuousClock().now
    }

    var minimumResolution: Duration {
        .nanoseconds(1)
    }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try await ContinuousClock().sleep(until: deadline, tolerance: tolerance)
    }
}

actor OperationGate {
    private var permits: Set<Int> = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func wait(for value: Int) async {
        if permits.remove(value) != nil {
            return
        }

        await withCheckedContinuation { continuation in
            waiters[value, default: []].append(continuation)
        }
    }

    func release(_ value: Int) {
        guard var valueWaiters = waiters[value], !valueWaiters.isEmpty else {
            permits.insert(value)
            return
        }

        let continuation = valueWaiters.removeFirst()
        if valueWaiters.isEmpty {
            waiters[value] = nil
        } else {
            waiters[value] = valueWaiters
        }
        continuation.resume()
    }
}

func waitWithTimeout<T: Sendable>(
    nanoseconds: UInt64 = 5_000_000_000,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: nanoseconds)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

func nextWithTimeout<Value: Sendable>(
    from queue: ValueQueue<Value>,
    nanoseconds: UInt64 = 5_000_000_000
) async -> Value? {
    await waitWithTimeout(nanoseconds: nanoseconds) {
        await queue.next()
    } ?? nil
}

func waitUntilValueReceived<Value: Sendable & Equatable>(
    _ expected: Value,
    from queue: ValueQueue<Value>,
    nanoseconds: UInt64 = 5_000_000_000
) async -> Bool {
    let reached = await waitWithTimeout(nanoseconds: nanoseconds) {
        while true {
            guard let next = await queue.next() else {
                return false
            }
            if next == expected {
                return true
            }
        }
    }
    return reached == true
}

func waitUntilCondition(
    nanoseconds: UInt64 = 5_000_000_000,
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock().now + .nanoseconds(Int64(nanoseconds))
    while ContinuousClock().now < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

@MainActor
func waitUntilMainActorCondition(
    nanoseconds: UInt64 = 5_000_000_000,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock().now + .nanoseconds(Int64(nanoseconds))
    while ContinuousClock().now < deadline {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}
