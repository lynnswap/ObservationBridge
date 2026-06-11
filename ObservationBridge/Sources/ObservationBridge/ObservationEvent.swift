import Observation

/// The trigger key path captured for a single portable observation pass.
///
/// `AnyKeyPath` instances are immutable reference types, so sharing them across
/// isolation domains is safe even though the type predates `Sendable`.
struct ObservationEventTriggers: @unchecked Sendable {
    private var keyPath: AnyKeyPath?

    /// No mutation triggered the pass (`.initial` passes).
    static let none = ObservationEventTriggers(keyPath: nil)

    /// A mutation of `keyPath` triggered the pass.
    static func keyPath(_ keyPath: AnyKeyPath?) -> ObservationEventTriggers {
        ObservationEventTriggers(keyPath: keyPath)
    }

    func contains(_ keyPath: AnyKeyPath) -> Bool {
        self.keyPath == keyPath
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

            public var description: String {
                switch rawValue {
                case .initial:
                    "initial"
                case .willSet:
                    "willSet"
                case .didSet:
                    "didSet"
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
        /// This mirrors Swift's `withContinuousObservation`: mutation passes compare the
        /// event's `ObservationTracking.changed` key path to `keyPath`, and `.initial`
        /// passes return `false`.
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
