/// A namespace for portable continuous observation API types.
public struct PortableObservationTracking: Sendable {}

extension PortableObservationTracking {
    /// Options for portable continuous observation callbacks.
    public struct Options: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8

        /// Re-runs the observation callback for a will-set event.
        public static let willSet = Options(rawValue: 1 << 0)

        /// Re-runs the observation callback after observed state changes.
        public static let didSet = Options(rawValue: 1 << 1)

        /// Creates observation options from a raw value.
        ///
        /// An empty option set delivers only the initial observation callback.
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }
    }
}
