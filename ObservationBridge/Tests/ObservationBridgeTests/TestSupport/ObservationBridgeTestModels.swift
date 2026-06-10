import Observation
import Foundation
import Synchronization
@testable import ObservationBridge

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

@MainActor
final class MainActorObservationScopeHolder {
    let observations = ObservationScope()
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
