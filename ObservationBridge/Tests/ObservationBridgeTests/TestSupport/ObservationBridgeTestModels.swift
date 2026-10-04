import Observation
import Foundation
import Synchronization
@testable import ObservationBridge

final class ObservationScope: @unchecked Sendable {
    private struct ID: Hashable, Sendable {
        let fileID: String
        let line: UInt
        let column: UInt
    }

    private struct State: Sendable {
        var cancellationGeneration: UInt64 = 0
        var tokens: [ID: PortableObservationTracking.Token] = [:]
    }

    private let storage = Mutex(State())

    @discardableResult
    func observe<Owner: AnyObject & Observable>(
        _ owner: Owner,
        options: PortableObservationTracking.Options = .didSet,
        @_inheritActorContext _ apply: @escaping @isolated(any) @Sendable (borrowing PortableObservationTracking.Event, Owner) -> Void,
        _ currentIsolation: isolated (any Actor)? = #isolation,
        _fileID: StaticString = #fileID,
        _line: UInt = #line,
        _column: UInt = #column
    ) -> PortableObservationTracking.Token {
        let pipeline = TestObservationScopePipeline(owner: owner, apply: apply)
        let cancellationGeneration = storage.withLock { state in
            state.cancellationGeneration
        }
        let token = withPortableContinuousObservation(
            options: options,
            apply: { event in
                pipeline.apply(event: event)
            },
            currentIsolation
        )
        let id = ID(fileID: "\(_fileID)", line: _line, column: _column)
        let insertion = storage.withLock { state -> (replaced: PortableObservationTracking.Token?, shouldCancel: Bool) in
            guard state.cancellationGeneration == cancellationGeneration else {
                return (nil, true)
            }
            return (state.tokens.updateValue(token, forKey: id), false)
        }
        insertion.replaced?.cancel()
        if insertion.shouldCancel {
            token.cancel()
        }
        return token
    }

    func cancelAll() {
        let tokens = storage.withLock { state in
            state.cancellationGeneration &+= 1
            let tokens = Array(state.tokens.values)
            state.tokens.removeAll()
            return tokens
        }
        for token in tokens {
            token.cancel()
        }
    }
}

private struct TestObservationScopePipeline: @unchecked Sendable {
    private final class WeakOwnerBox: @unchecked Sendable {
        weak var value: AnyObject?
    }

    private let weakOwner: WeakOwnerBox
    private let applyCallback: @Sendable (borrowing PortableObservationTracking.Event, AnyObject) -> Void

    init<Owner: AnyObject>(
        owner: Owner,
        apply: @escaping @isolated(any) @Sendable (borrowing PortableObservationTracking.Event, Owner) -> Void
    ) {
        weakOwner = WeakOwnerBox()
        weakOwner.value = owner
        applyCallback = unsafe unsafeBitCast(
            apply,
            to: (@Sendable (borrowing PortableObservationTracking.Event, AnyObject) -> Void).self
        )
    }

    func apply(event: borrowing PortableObservationTracking.Event) {
        guard let owner = weakOwner.value else {
            event.cancel()
            return
        }

        applyCallback(event, owner)
    }
}

@Observable
final class CounterModel: @unchecked Sendable {
    var value: Int = 0
    var secondaryValue: Int = 0
    var isEnabled: Bool = false
    var name: String = ""
    var parity: Int { value % 2 }
}

@Observable
final class PlainCounterModel {
    var value: Int = 0
}

@Observable
final class LockedCounterModel: Sendable {
    @ObservationIgnored
    private let valueStorage = Mutex<Int>(0)

    var value: Int {
        get {
            access(keyPath: \.value)
            return valueStorage.withLock { $0 }
        }
        set {
            withMutation(keyPath: \.value) {
                valueStorage.withLock { $0 = newValue }
            }
        }
    }

    func writeAndRead(_ newValue: Int) -> Int {
        withMutation(keyPath: \.value) {
            valueStorage.withLock {
                $0 = newValue
                return $0
            }
        }
    }
}

@Observable
final class DelayedMutationCounterModel: Sendable {
    @ObservationIgnored
    private let valueStorage = Mutex<Int>(0)

    var value: Int {
        get {
            access(keyPath: \.value)
            return valueStorage.withLock { $0 }
        }
        set {
            withMutation(keyPath: \.value) {
                Thread.sleep(forTimeInterval: 0.05)
                valueStorage.withLock { $0 = newValue }
            }
        }
    }
}

@Observable
final class OptionalCounterModel: @unchecked Sendable {
    var value: Int? = nil
}

struct NestedCounterPayload: Sendable {
    var value: Int = 0
}

@Observable
final class NestedCounterModel: @unchecked Sendable {
    var payload = NestedCounterPayload()
}

@MainActor
@Observable
final class MainActorCounterModel {
    var value: Int = 0
    var isEnabled: Bool = false
    var parity: Int { value % 2 }
}

@MainActor
@Observable
final class MainActorOptionalCounterModel {
    var value: Int? = nil
}

final class ObservationCancellationProbe: @unchecked Sendable {
    private let storage = Mutex<PortableObservationTracking.Token?>(nil)

    func set(_ token: PortableObservationTracking.Token) {
        storage.withLock { storedToken in
            storedToken = token
        }
    }

    func cancel() {
        let token = storage.withLock { storedToken in
            storedToken
        }
        token?.cancel()
    }
}

final class ObservationScopeCancellationProbe: @unchecked Sendable {
    let observations = ObservationScope()

    func cancelAll() {
        observations.cancelAll()
    }
}

@Observable
final class ChildContainerModel: @unchecked Sendable {
    var value: Int = 0
    var child: ChildProbeModel?
}

@Observable
final class ChildProbeModel: @unchecked Sendable {
    var value: Int

    init(value: Int) {
        self.value = value
    }
}

final class WeakBox<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?
}

typealias WeakChildProbeModelBox = WeakBox<ChildProbeModel>

final class NonSendablePayload {
    let value: Int

    init(value: Int) {
        self.value = value
    }
}

@MainActor
@Observable
final class MainActorNonSendablePayloadModel {
    var payload = NonSendablePayload(value: 0)
}

@Observable
final class DeinitProbeCounterModel: @unchecked Sendable {
    var value: Int = 0
    private let onDeinit: @Sendable () -> Void

    init(onDeinit: @escaping @Sendable () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }
}

final class CallbackCaptureProbe: @unchecked Sendable {
    private let storage = Mutex<Int?>(nil)
    private let onDeinit: @Sendable () -> Void

    init(onDeinit: @escaping @Sendable () -> Void) {
        self.onDeinit = onDeinit
    }

    func record(_ value: Int) {
        storage.withLock { storedValue in
            storedValue = value
        }
    }

    deinit {
        onDeinit()
    }
}

actor DeinitFlag {
    private(set) var didDeinit = false

    func mark() {
        didDeinit = true
    }
}
