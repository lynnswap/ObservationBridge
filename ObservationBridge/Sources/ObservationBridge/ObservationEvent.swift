import Observation

/// Information about a single owner-bound observation pass.
public struct ObservationEvent: Sendable {
    /// The reason the observation callback is running.
    public struct Kind: Sendable, Equatable, Hashable, CustomStringConvertible {
        private enum RawValue: UInt8, Sendable {
            case initial
            #if compiler(>=6.4)
            case willSet
            #endif
            case didSet
        }

        private let rawValue: RawValue

        /// The initial tracking pass.
        public static var initial: Kind {
            Kind(rawValue: .initial)
        }

        #if compiler(>=6.4)
        /// A pass triggered before a tracked property mutation.
        @available(*, unavailable, message: "ObservationEvent.Kind.willSet is reserved for the Swift 6.4 native backend.")
        public static var willSet: Kind {
            Kind(rawValue: .willSet)
        }
        #endif

        /// A pass after observed state changed.
        public static var didSet: Kind {
            Kind(rawValue: .didSet)
        }

        public var description: String {
            switch rawValue {
            case .initial:
                "initial"
            #if compiler(>=6.4)
            case .willSet:
                "willSet"
            #endif
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

    private weak var slot: ObservationScopeSlot?

    init(
        kind: Kind,
        slot: ObservationScopeSlot
    ) {
        self.kind = kind
        self.slot = slot
    }

    #if compiler(>=6.4)
    /// Returns whether this event was triggered by the supplied key path.
    @available(*, unavailable, message: "ObservationEvent.matches(_:) is reserved for the Swift 6.4 native backend.")
    public func matches(_ keyPath: PartialKeyPath<some Observable>) -> Bool {
        false
    }
    #endif

    /// Cancels the current observation.
    public func cancel() {
        slot?.cancel()
    }
}
