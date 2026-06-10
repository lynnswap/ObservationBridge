/// Options for portable continuous observation callbacks.
public struct ObservationOptions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    /// Re-runs the observation callback for a will-set event.
    public static let willSet = ObservationOptions(rawValue: 1 << 0)

    /// Re-runs the observation callback after observed state changes.
    public static let didSet = ObservationOptions(rawValue: 1 << 1)

    #if compiler(>=6.4)
    /// Re-runs the observation callback after a tracked observable dependency is deinitialized.
    @available(anyAppleOS 27.0, *)
    public static let `deinit` = ObservationOptions(rawValue: 1 << 2)
    #endif

    /// Creates observation options from a raw value.
    ///
    /// An empty option set delivers only the initial observation callback.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

}
