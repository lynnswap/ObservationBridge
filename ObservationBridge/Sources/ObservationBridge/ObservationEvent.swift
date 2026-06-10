import Observation

/// Information about a single owner-bound observation pass.
public struct ObservationEvent: ~Copyable {
    /// The reason the observation callback is running.
    public struct Kind: Sendable, Equatable, Hashable, CustomStringConvertible {
        private enum RawValue: UInt8, Sendable {
            case initial
            #if compiler(>=6.4)
            case willSet
            #endif
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

        #if compiler(>=6.4)
        /// A pass triggered by a will-set event.
        public static var willSet: Kind {
            Kind(rawValue: .willSet)
        }
        #endif

        /// A pass after observed state changed.
        public static var didSet: Kind {
            Kind(rawValue: .didSet)
        }

        #if compiler(>=6.4)
        /// A pass triggered after a tracked observable dependency is deinitialized.
        @available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)
        public static var `deinit`: Kind {
            Kind(rawValue: .deinit)
        }
        #endif

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

    private let cancellation: (@Sendable () -> Void)?

    init(
        kind: Kind,
        cancellation: (@Sendable () -> Void)? = nil
    ) {
        self.kind = kind
        self.cancellation = cancellation
    }

    #if compiler(>=6.4)
    /// Returns whether this event was triggered by the supplied key path.
    @available(*, unavailable, message: "ObservationEvent.matches(_:) is reserved for the Swift 6.4 native backend.")
    public func matches(_ keyPath: PartialKeyPath<some Observable>) -> Bool {
        false
    }
    #endif

    /// Cancels the event's backing tracking when one is available.
    public func cancel() {
        cancellation?()
    }
}
