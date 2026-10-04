/// A namespace for portable continuous observation API types.
public struct PortableObservationTracking: Sendable {}

extension PortableObservationTracking {
    /// Options for portable continuous observation callbacks.
    ///
    /// The initial pass is always delivered. An empty set requests no subsequent
    /// passes, and the default option is ``didSet``. When both ``willSet`` and
    /// ``didSet`` are requested, a normal mutation produces one did-set pass.
    public struct Options: OptionSet, Sendable, Hashable {
        /// The bit mask representing the selected event options.
        public let rawValue: UInt8

        /// Re-runs the observation callback for a will-set event.
        ///
        /// The event identifies the mutation trigger. Callback reads may already
        /// include the new value because delivery follows continuous observation
        /// scheduling.
        public static let willSet = Options(rawValue: 1 << 0)

        /// Re-runs the observation callback after observed state changes.
        public static let didSet = Options(rawValue: 1 << 1)

        /// Creates observation options from a raw value.
        ///
        /// An empty option set delivers only the initial observation callback.
        ///
        /// - Parameter rawValue: The bit mask representing the selected event options.
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }
    }
}
