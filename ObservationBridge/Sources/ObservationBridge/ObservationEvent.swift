import Observation

/// The trigger key paths captured for a single portable observation pass.
///
/// `AnyKeyPath` instances are immutable reference types, so sharing them across
/// isolation domains is safe even though the type predates `Sendable`.
struct ObservationEventTriggers: @unchecked Sendable {
    private enum Storage {
        case none
        case unknown
        case single(AnyKeyPath)
        case many(Set<AnyKeyPath>)
    }

    private var storage: Storage

    /// No mutation triggered the pass (`.initial` and `.deinit` passes).
    static let none = ObservationEventTriggers(storage: .none)

    /// A mutation triggered the pass but its key path could not be captured.
    static let unknown = ObservationEventTriggers(storage: .unknown)

    /// A mutation of `keyPath` triggered the pass; `nil` degrades to ``unknown``.
    static func keyPath(_ keyPath: AnyKeyPath?) -> ObservationEventTriggers {
        guard let keyPath else {
            return .unknown
        }
        return ObservationEventTriggers(storage: .single(keyPath))
    }

    private init(storage: Storage) {
        self.storage = storage
    }

    func contains(_ keyPath: AnyKeyPath) -> Bool {
        switch storage {
        case .none:
            false
        case .unknown:
            true
        case .single(let trigger):
            trigger == keyPath
        case .many(let triggers):
            triggers.contains(keyPath)
        }
    }

    mutating func formUnion(_ other: ObservationEventTriggers) {
        switch (storage, other.storage) {
        case (_, .none):
            break
        case (.none, _):
            storage = other.storage
        case (.unknown, _), (_, .unknown):
            storage = .unknown
        case (.single(let trigger), .single(let otherTrigger)):
            if trigger != otherTrigger {
                storage = .many([trigger, otherTrigger])
            }
        case (.single(let trigger), .many(let otherTriggers)):
            storage = .many(otherTriggers.union([trigger]))
        case (.many(var triggers), .single(let otherTrigger)):
            triggers.insert(otherTrigger)
            storage = .many(triggers)
        case (.many(var triggers), .many(let otherTriggers)):
            triggers.formUnion(otherTriggers)
            storage = .many(triggers)
        }
    }
}

extension PortableObservationTracking {
    /// Information about a single portable observation pass.
    public struct Event: ~Copyable {
        /// The reason the observation callback is running.
        public struct Kind: Sendable, Equatable, Hashable, CustomStringConvertible {
            private enum RawValue: UInt8, Sendable {
                case initial
                case willSet
                case didSet
                #if compiler(>=6.4)
                case `deinit`
                #endif
            }

            private let rawValue: RawValue

            /// The initial tracking pass.
            public static var initial: Kind {
                Kind(rawValue: .initial)
            }

            /// A pass triggered by a will-set event.
            public static var willSet: Kind {
                Kind(rawValue: .willSet)
            }

            /// A pass after observed state changed.
            public static var didSet: Kind {
                Kind(rawValue: .didSet)
            }

            #if compiler(>=6.4)
            /// A pass triggered after a tracked observable dependency is deinitialized.
            @available(anyAppleOS 27.0, *)
            public static var `deinit`: Kind {
                Kind(rawValue: .deinit)
            }
            #endif

            public var description: String {
                switch rawValue {
                case .initial:
                    "initial"
                case .willSet:
                    "willSet"
                case .didSet:
                    "didSet"
                #if compiler(>=6.4)
                case .deinit:
                    "deinit"
                #endif
                }
            }

            private init(rawValue: RawValue) {
                self.rawValue = rawValue
            }
        }

        /// The reason the observation callback is running.
        public let kind: Kind

        private let triggers: ObservationEventTriggers

        private let cancellation: (@Sendable () -> Void)?

        init(
            kind: Kind,
            triggers: ObservationEventTriggers = .none,
            cancellation: (@Sendable () -> Void)? = nil
        ) {
            self.kind = kind
            self.triggers = triggers
            self.cancellation = cancellation
        }

        /// Returns whether this pass was triggered by a mutation of the supplied key path.
        ///
        /// A coalesced pass can stand for multiple mutations; this returns `true` when any of
        /// them used `keyPath`. `.initial` and `.deinit` passes return `false`. When trigger
        /// key paths cannot be captured (including the Swift 6.4 / OS 27+ native backend),
        /// this conservatively returns `true` for every key path so callers never skip work
        /// for a mutation that did happen.
        ///
        /// Key paths carry no instance identity: two tracked objects of the same type are
        /// indistinguishable, and the comparison is exact, so a subclass-rooted key path does
        /// not match its superclass storage.
        public func matches(_ keyPath: PartialKeyPath<some Observable>) -> Bool {
            triggers.contains(keyPath)
        }

        /// Cancels the event's backing tracking when one is available.
        public func cancel() {
            cancellation?()
        }
    }
}
