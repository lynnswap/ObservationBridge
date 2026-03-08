import Observation
internal import _ObservationBridgeLegacy

public enum ObservationDebounceMode: Sendable, Hashable {
    case immediateFirst
    case delayedFirst
}

public struct ObservationDebounce: Sendable, Hashable {
    public let interval: Duration
    public let tolerance: Duration?
    public let mode: ObservationDebounceMode

    public init(
        interval: Duration,
        tolerance: Duration? = nil,
        mode: ObservationDebounceMode = .immediateFirst
    ) {
        self.interval = interval
        self.tolerance = tolerance
        self.mode = mode
    }
}

public enum ObservationThrottleMode: Sendable, Hashable {
    case latest
    case earliest
}

public struct ObservationThrottle: Sendable, Hashable {
    public let interval: Duration
    public let mode: ObservationThrottleMode

    public init(
        interval: Duration,
        mode: ObservationThrottleMode = .latest
    ) {
        self.interval = interval
        self.mode = mode
    }
}

public enum ObservationRateLimit: Sendable, Hashable {
    case debounce(ObservationDebounce)
    case throttle(ObservationThrottle)
}

public struct ObservationOptions: OptionSet, Sendable {
    private static let removeDuplicatesFlag: UInt64 = 1 << 0
    private static let rateLimitFlag: UInt64 = 1 << 1
    private static let rateLimitModeFlag: UInt64 = 1 << 2
    private static let rateLimitTolerancePresentFlag: UInt64 = 1 << 3
    private static let conflictingRateLimitFlag: UInt64 = 1 << 60
    private static let legacyBackendFlag: UInt64 = 1 << 61
    private static let rateLimitEncodingVersionFlag: UInt64 = 1 << 62
    private static let rateLimitKindThrottleFlag: UInt64 = 1 << 63
    private static let rateLimitPayloadBitWidth: UInt64 = 28
    private static let rateLimitIntervalShift: UInt64 = 4
    private static let rateLimitToleranceShift: UInt64 = rateLimitIntervalShift + rateLimitPayloadBitWidth
    private static let rateLimitPayloadMask: UInt64 = (1 << rateLimitPayloadBitWidth) - 1
    private static let rateLimitIntervalMask: UInt64 = rateLimitPayloadMask << rateLimitIntervalShift
    private static let rateLimitToleranceMask: UInt64 = rateLimitPayloadMask << rateLimitToleranceShift
    private static let legacyDebounceFlag = rateLimitFlag
    private static let legacyDelayedFirstFlag: UInt64 = 1 << 2
    private static let legacyTolerancePresentFlag: UInt64 = 1 << 3
    private static let legacyDebounceIntervalShift: UInt64 = 4
    private static let legacyDebounceToleranceShift: UInt64 = legacyDebounceIntervalShift + rateLimitPayloadBitWidth
    private static let legacyDebounceIntervalMask: UInt64 = rateLimitPayloadMask << legacyDebounceIntervalShift
    private static let legacyDebounceToleranceMask: UInt64 = rateLimitPayloadMask << legacyDebounceToleranceShift
    private static let membershipMask: UInt64 = removeDuplicatesFlag | rateLimitFlag | legacyBackendFlag

    public let rawValue: UInt64
    private let rateLimitConfiguration: ObservationRateLimit?
    private let hasConflictingRateLimit: Bool

    public init() {
        rawValue = 0
        rateLimitConfiguration = nil
        hasConflictingRateLimit = false
    }

    public init(rawValue: UInt64) {
        let removeDuplicates = (rawValue & Self.removeDuplicatesFlag) != 0
        let usesLegacyBackend = (rawValue & Self.legacyBackendFlag) != 0
        let hasConflictingRateLimit = (rawValue & Self.conflictingRateLimitFlag) != 0
        let rateLimitConfiguration = hasConflictingRateLimit ? nil : Self.decodeRateLimitConfiguration(from: rawValue)
        self.rawValue = Self.encodeRawValue(
            removeDuplicates: removeDuplicates,
            usesLegacyBackend: usesLegacyBackend,
            rateLimitConfiguration: rateLimitConfiguration,
            hasConflictingRateLimit: hasConflictingRateLimit
        )
        self.rateLimitConfiguration = rateLimitConfiguration
        self.hasConflictingRateLimit = hasConflictingRateLimit
    }

    private init(
        removeDuplicates: Bool,
        usesLegacyBackend: Bool,
        rateLimitConfiguration: ObservationRateLimit?,
        hasConflictingRateLimit: Bool = false
    ) {
        let normalizedRateLimitConfiguration = hasConflictingRateLimit
            ? nil
            : Self.normalizeRateLimitConfiguration(rateLimitConfiguration)
        self.rawValue = Self.encodeRawValue(
            removeDuplicates: removeDuplicates,
            usesLegacyBackend: usesLegacyBackend,
            rateLimitConfiguration: normalizedRateLimitConfiguration,
            hasConflictingRateLimit: hasConflictingRateLimit
        )
        self.rateLimitConfiguration = normalizedRateLimitConfiguration
        self.hasConflictingRateLimit = hasConflictingRateLimit
    }

    public init(arrayLiteral elements: ObservationOptions...) {
        var merged = ObservationOptions()
        for element in elements {
            merged.formUnion(element)
        }
        self = merged
    }

    public static let removeDuplicates = ObservationOptions(rawValue: removeDuplicatesFlag)

    @available(iOS 26.0, macOS 26.0, *)
    public static let legacyBackend = ObservationOptions(rawValue: legacyBackendFlag)

    public static func rateLimit(_ configuration: ObservationRateLimit) -> ObservationOptions {
        ObservationOptions(removeDuplicates: false, usesLegacyBackend: false, rateLimitConfiguration: configuration)
    }

    @available(*, deprecated, message: "Use .rateLimit(.debounce(configuration)) instead.")
    public static func debounce(_ configuration: ObservationDebounce) -> ObservationOptions {
        rateLimit(.debounce(configuration))
    }

    public var rateLimit: ObservationRateLimit? {
        rateLimitConfiguration
    }

    @available(*, deprecated, message: "Inspect options.rateLimit and pattern-match .debounce instead.")
    public var debounce: ObservationDebounce? {
        guard case let .debounce(configuration)? = rateLimitConfiguration else {
            return nil
        }
        return configuration
    }

    var hasRateLimitConflict: Bool {
        hasConflictingRateLimit
    }

    var rateLimitForObservation: ObservationRateLimit? {
        guard !hasRateLimitConflict else {
            preconditionFailure("Conflicting rate limit options are not supported when starting observation")
        }
        return rateLimitConfiguration
    }

    var forcesLegacyBackend: Bool {
        (rawValue & Self.legacyBackendFlag) != 0
    }

    public func contains(_ member: ObservationOptions) -> Bool {
        let ownMembership = rawValue & Self.membershipMask
        let memberMembership = member.rawValue & Self.membershipMask
        guard (ownMembership & memberMembership) == memberMembership else {
            return false
        }
        if member.hasConflictingRateLimit {
            return hasConflictingRateLimit
        }
        guard let memberRateLimitConfiguration = member.rateLimitConfiguration else {
            return true
        }
        return rateLimitConfiguration == memberRateLimitConfiguration
    }

    public func union(_ other: ObservationOptions) -> ObservationOptions {
        let removeDuplicates = (rawValue & Self.removeDuplicatesFlag) != 0 || (other.rawValue & Self.removeDuplicatesFlag) != 0
        let usesLegacyBackend = (rawValue & Self.legacyBackendFlag) != 0 || (other.rawValue & Self.legacyBackendFlag) != 0
        let mergedRateLimit = Self.mergeRateLimit(
            lhs: rateLimitConfiguration,
            lhsConflicting: hasConflictingRateLimit,
            rhs: other.rateLimitConfiguration,
            rhsConflicting: other.hasConflictingRateLimit
        )
        return ObservationOptions(
            removeDuplicates: removeDuplicates,
            usesLegacyBackend: usesLegacyBackend,
            rateLimitConfiguration: mergedRateLimit.configuration,
            hasConflictingRateLimit: mergedRateLimit.hasConflict
        )
    }

    public mutating func formUnion(_ other: ObservationOptions) {
        self = union(other)
    }

    public func intersection(_ other: ObservationOptions) -> ObservationOptions {
        let removeDuplicates = (rawValue & Self.removeDuplicatesFlag) != 0 && (other.rawValue & Self.removeDuplicatesFlag) != 0
        let usesLegacyBackend = (rawValue & Self.legacyBackendFlag) != 0 && (other.rawValue & Self.legacyBackendFlag) != 0
        let intersectedConflict = hasConflictingRateLimit && other.hasConflictingRateLimit
        let intersectedRateLimit = intersectedConflict ? nil : (rateLimitConfiguration == other.rateLimitConfiguration ? rateLimitConfiguration : nil)
        return ObservationOptions(
            removeDuplicates: removeDuplicates,
            usesLegacyBackend: usesLegacyBackend,
            rateLimitConfiguration: intersectedRateLimit,
            hasConflictingRateLimit: intersectedConflict
        )
    }

    public mutating func formIntersection(_ other: ObservationOptions) {
        self = intersection(other)
    }

    public func symmetricDifference(_ other: ObservationOptions) -> ObservationOptions {
        let removeDuplicates = ((rawValue & Self.removeDuplicatesFlag) != 0) != ((other.rawValue & Self.removeDuplicatesFlag) != 0)
        let usesLegacyBackend = ((rawValue & Self.legacyBackendFlag) != 0) != ((other.rawValue & Self.legacyBackendFlag) != 0)
        let resultingConflict = hasConflictingRateLimit != other.hasConflictingRateLimit
        let resultingRateLimit: ObservationRateLimit?
        if resultingConflict {
            resultingRateLimit = nil
        } else {
            switch (rateLimitConfiguration, other.rateLimitConfiguration) {
            case (nil, nil):
                resultingRateLimit = nil
            case let (lhs?, nil):
                resultingRateLimit = lhs
            case let (nil, rhs?):
                resultingRateLimit = rhs
            case (.some, .some):
                resultingRateLimit = nil
            }
        }

        return ObservationOptions(
            removeDuplicates: removeDuplicates,
            usesLegacyBackend: usesLegacyBackend,
            rateLimitConfiguration: resultingRateLimit,
            hasConflictingRateLimit: resultingConflict
        )
    }

    public mutating func formSymmetricDifference(_ other: ObservationOptions) {
        self = symmetricDifference(other)
    }

    public func subtracting(_ other: ObservationOptions) -> ObservationOptions {
        let removeDuplicates = (rawValue & Self.removeDuplicatesFlag) != 0 && (other.rawValue & Self.removeDuplicatesFlag) == 0
        let usesLegacyBackend = (rawValue & Self.legacyBackendFlag) != 0 && (other.rawValue & Self.legacyBackendFlag) == 0
        let resultingConflict: Bool
        let resultingRateLimit: ObservationRateLimit?
        if hasConflictingRateLimit {
            resultingConflict = !other.hasConflictingRateLimit
            resultingRateLimit = nil
        } else {
            resultingConflict = false
            resultingRateLimit = rateLimitConfiguration == other.rateLimitConfiguration ? nil : rateLimitConfiguration
        }
        return ObservationOptions(
            removeDuplicates: removeDuplicates,
            usesLegacyBackend: usesLegacyBackend,
            rateLimitConfiguration: resultingRateLimit,
            hasConflictingRateLimit: resultingConflict
        )
    }

    public mutating func subtract(_ other: ObservationOptions) {
        self = subtracting(other)
    }

    @discardableResult
    public mutating func insert(_ newMember: ObservationOptions) -> (inserted: Bool, memberAfterInsert: ObservationOptions) {
        let oldMember = update(with: newMember)
        return (oldMember == nil, oldMember ?? newMember)
    }

    @discardableResult
    public mutating func remove(_ member: ObservationOptions) -> ObservationOptions? {
        guard contains(member) else {
            return nil
        }
        let removedMember = intersection(member)
        self = subtracting(member)
        return removedMember
    }

    @discardableResult
    public mutating func update(with newMember: ObservationOptions) -> ObservationOptions? {
        let oldMember = contains(newMember) ? intersection(newMember) : nil
        self = union(newMember)
        return oldMember
    }

    private static func encodeRawValue(
        removeDuplicates: Bool,
        usesLegacyBackend: Bool,
        rateLimitConfiguration: ObservationRateLimit?,
        hasConflictingRateLimit: Bool
    ) -> UInt64 {
        var rawValue: UInt64 = removeDuplicates ? removeDuplicatesFlag : 0
        if usesLegacyBackend {
            rawValue |= legacyBackendFlag
        }
        if hasConflictingRateLimit {
            rawValue |= conflictingRateLimitFlag
            return rawValue
        }
        guard let rateLimitConfiguration else {
            return rawValue
        }

        rawValue |= rateLimitFlag
        rawValue |= rateLimitEncodingVersionFlag
        rawValue |= encodeRateLimitPayload(rateLimitConfiguration)
        return rawValue
    }

    private static func decodeRateLimitConfiguration(from rawValue: UInt64) -> ObservationRateLimit? {
        guard (rawValue & rateLimitFlag) != 0 else {
            return nil
        }

        if (rawValue & rateLimitEncodingVersionFlag) == 0 {
            return decodeLegacyDebounceConfiguration(from: rawValue).map(ObservationRateLimit.debounce)
        }

        let intervalMilliseconds = (rawValue & rateLimitIntervalMask) >> rateLimitIntervalShift
        let interval = Duration.milliseconds(Int64(intervalMilliseconds))

        if (rawValue & rateLimitKindThrottleFlag) != 0 {
            let mode: ObservationThrottleMode = (rawValue & rateLimitModeFlag) != 0 ? .earliest : .latest
            return .throttle(
                ObservationThrottle(
                    interval: interval,
                    mode: mode
                )
            )
        }

        let mode: ObservationDebounceMode = (rawValue & rateLimitModeFlag) != 0 ? .delayedFirst : .immediateFirst
        let tolerance: Duration?
        if (rawValue & rateLimitTolerancePresentFlag) != 0 {
            let toleranceMilliseconds = (rawValue & rateLimitToleranceMask) >> rateLimitToleranceShift
            tolerance = .milliseconds(Int64(toleranceMilliseconds))
        } else {
            tolerance = nil
        }

        return .debounce(
            ObservationDebounce(
                interval: interval,
                tolerance: tolerance,
                mode: mode
            )
        )
    }

    private static func decodeLegacyDebounceConfiguration(from rawValue: UInt64) -> ObservationDebounce? {
        guard (rawValue & legacyDebounceFlag) != 0 else {
            return nil
        }

        let mode: ObservationDebounceMode = (rawValue & legacyDelayedFirstFlag) != 0 ? .delayedFirst : .immediateFirst
        let intervalMilliseconds = (rawValue & legacyDebounceIntervalMask) >> legacyDebounceIntervalShift
        let interval = Duration.milliseconds(Int64(intervalMilliseconds))

        let tolerance: Duration?
        if (rawValue & legacyTolerancePresentFlag) != 0 {
            let toleranceMilliseconds = (rawValue & legacyDebounceToleranceMask) >> legacyDebounceToleranceShift
            tolerance = .milliseconds(Int64(toleranceMilliseconds))
        } else {
            tolerance = nil
        }

        return ObservationDebounce(
            interval: interval,
            tolerance: tolerance,
            mode: mode
        )
    }

    private static func normalizeRateLimitConfiguration(_ rateLimitConfiguration: ObservationRateLimit?) -> ObservationRateLimit? {
        guard let rateLimitConfiguration else {
            return nil
        }
        let encodedRawValue = rateLimitFlag | rateLimitEncodingVersionFlag | encodeRateLimitPayload(rateLimitConfiguration)
        return decodeRateLimitConfiguration(from: encodedRawValue)
    }

    private static func encodeRateLimitPayload(_ rateLimitConfiguration: ObservationRateLimit) -> UInt64 {
        switch rateLimitConfiguration {
        case let .debounce(debounceConfiguration):
            let intervalMilliseconds = encodeMilliseconds(
                debounceConfiguration.interval,
                parameter: "interval"
            )

            var payload = intervalMilliseconds << rateLimitIntervalShift
            if debounceConfiguration.mode == .delayedFirst {
                payload |= rateLimitModeFlag
            }

            if let tolerance = debounceConfiguration.tolerance {
                let toleranceMilliseconds = encodeMilliseconds(
                    tolerance,
                    parameter: "tolerance"
                )
                payload |= rateLimitTolerancePresentFlag
                payload |= toleranceMilliseconds << rateLimitToleranceShift
            }

            return payload
        case let .throttle(throttleConfiguration):
            let intervalMilliseconds = encodeMilliseconds(
                throttleConfiguration.interval,
                parameter: "interval"
            )

            var payload = rateLimitKindThrottleFlag
            payload |= intervalMilliseconds << rateLimitIntervalShift
            if throttleConfiguration.mode == .earliest {
                payload |= rateLimitModeFlag
            }
            return payload
        }
    }

    private static func encodeMilliseconds(
        _ duration: Duration,
        parameter: String
    ) -> UInt64 {
        let components = duration.components
        precondition(
            components.seconds >= 0 && components.attoseconds >= 0,
            "\(parameter) must be non-negative"
        )

        let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
        let (secondsMilliseconds, secondsOverflow) = UInt64(components.seconds).multipliedReportingOverflow(by: 1_000)
        precondition(!secondsOverflow, "\(parameter) is too large to encode")

        let attosecondsMilliseconds = UInt64(components.attoseconds / attosecondsPerMillisecond)
        let remainderAttoseconds = UInt64(components.attoseconds % attosecondsPerMillisecond)
        let roundedMilliseconds: UInt64 = remainderAttoseconds >= UInt64(attosecondsPerMillisecond / 2) ? 1 : 0

        let (partialMilliseconds, partialOverflow) = secondsMilliseconds.addingReportingOverflow(attosecondsMilliseconds)
        precondition(!partialOverflow, "\(parameter) is too large to encode")
        let (totalMilliseconds, totalOverflow) = partialMilliseconds.addingReportingOverflow(roundedMilliseconds)
        precondition(!totalOverflow, "\(parameter) is too large to encode")

        precondition(
            totalMilliseconds <= rateLimitPayloadMask,
            "\(parameter) is too large to encode"
        )
        return totalMilliseconds
    }

    private struct RateLimitMergeResult {
        let configuration: ObservationRateLimit?
        let hasConflict: Bool
    }

    private static func mergeRateLimit(
        lhs: ObservationRateLimit?,
        lhsConflicting: Bool,
        rhs: ObservationRateLimit?,
        rhsConflicting: Bool
    ) -> RateLimitMergeResult {
        if lhsConflicting || rhsConflicting {
            return RateLimitMergeResult(configuration: nil, hasConflict: true)
        }

        switch (lhs, rhs) {
        case (nil, nil):
            return RateLimitMergeResult(configuration: nil, hasConflict: false)
        case let (lhs?, nil):
            return RateLimitMergeResult(configuration: lhs, hasConflict: false)
        case let (nil, rhs?):
            return RateLimitMergeResult(configuration: rhs, hasConflict: false)
        case let (lhs?, rhs?):
            if lhs == rhs {
                return RateLimitMergeResult(configuration: lhs, hasConflict: false)
            }
            return RateLimitMergeResult(configuration: nil, hasConflict: true)
        }
    }
}

public extension Observable where Self: AnyObject {
    @discardableResult
    func observe<Value: Sendable>(
        _ keyPath: sending KeyPath<Self, Value>,
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates requires Value to conform to Equatable")
        }

        return observeImpl(
            owner: self,
            options: options,
            duplicateFilter: nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: makeKeyPathGetter(keyPath),
            onChange: makeOnChangeAdapter(onChange)
        )
    }

    @discardableResult
    func observe<Value: Sendable>(
        _ keyPath: sending KeyPath<Self, Value>,
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable () -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates requires Value to conform to Equatable")
        }

        return observeImpl(
            owner: self,
            options: options,
            duplicateFilter: nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: makeKeyPathGetter(keyPath),
            onChange: { _ in
                await onChange()
            }
        )
    }

    @discardableResult
    func observe<Value: Sendable & Equatable>(
        _ keyPath: sending KeyPath<Self, Value>,
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        observeImpl(
            owner: self,
            options: options,
            duplicateFilter: options.contains(.removeDuplicates) ? makeEquatableDuplicateFilterSendable() : nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: makeKeyPathGetter(keyPath),
            onChange: makeOnChangeAdapter(onChange)
        )
    }

    @discardableResult
    func observe<Value: Sendable & Equatable>(
        _ keyPath: sending KeyPath<Self, Value>,
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable () -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        observeImpl(
            owner: self,
            options: options,
            duplicateFilter: options.contains(.removeDuplicates) ? makeEquatableDuplicateFilterSendable() : nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: makeKeyPathGetter(keyPath),
            onChange: { _ in
                await onChange()
            }
        )
    }

    @discardableResult
    func observeTask<Value: Sendable>(
        _ keyPath: sending KeyPath<Self, Value>,
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending Value) async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates requires Value to conform to Equatable")
        }

        return observeTaskImpl(
            owner: self,
            options: options,
            duplicateFilter: nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: makeKeyPathGetter(keyPath),
            task: task
        )
    }

    @discardableResult
    func observeTask<Value: Sendable>(
        _ keyPath: sending KeyPath<Self, Value>,
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext task: @escaping @isolated(any) @Sendable () async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates requires Value to conform to Equatable")
        }

        return observeTaskImpl(
            owner: self,
            options: options,
            duplicateFilter: nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: makeKeyPathGetter(keyPath),
            task: { _ in
                await task()
            }
        )
    }

    @discardableResult
    func observeTask<Value: Sendable & Equatable>(
        _ keyPath: sending KeyPath<Self, Value>,
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending Value) async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        observeTaskImpl(
            owner: self,
            options: options,
            duplicateFilter: options.contains(.removeDuplicates) ? makeEquatableDuplicateFilterSendable() : nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: makeKeyPathGetter(keyPath),
            task: task
        )
    }

    @discardableResult
    func observeTask<Value: Sendable & Equatable>(
        _ keyPath: sending KeyPath<Self, Value>,
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext task: @escaping @isolated(any) @Sendable () async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        observeTaskImpl(
            owner: self,
            options: options,
            duplicateFilter: options.contains(.removeDuplicates) ? makeEquatableDuplicateFilterSendable() : nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: makeKeyPathGetter(keyPath),
            task: { _ in
                await task()
            }
        )
    }

    @discardableResult
    func observe(
        _ keyPaths: sending [PartialKeyPath<Self>],
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable () -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates is not supported for multiple key path trigger observation")
        }

        return observeImpl(
            owner: self,
            options: options,
            duplicateFilter: nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: makeAnyKeyPathsTriggerGetter(keyPaths),
            onChange: { _ in
                await onChange()
            }
        )
    }

    @discardableResult
    func observeTask(
        _ keyPaths: sending [PartialKeyPath<Self>],
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext task: @escaping @isolated(any) @Sendable () async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates is not supported for multiple key path trigger observation")
        }

        return observeTaskImpl(
            owner: self,
            options: options,
            duplicateFilter: nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: makeAnyKeyPathsTriggerGetter(keyPaths),
            task: { _ in
                await task()
            }
        )
    }

    @discardableResult
    func observe<Value: Sendable>(
        _ keyPaths: sending [PartialKeyPath<Self>],
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        of value: @escaping @Sendable (Self) -> Value,
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates requires Value to conform to Equatable")
        }

        return observeImpl(
            owner: self,
            options: options,
            duplicateFilter: nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: makeAnyKeyPathsValueGetter(keyPaths, of: value),
            onChange: makeOnChangeAdapter(onChange)
        )
    }

    @discardableResult
    func observe<Value: Sendable & Equatable>(
        _ keyPaths: sending [PartialKeyPath<Self>],
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        of value: @escaping @Sendable (Self) -> Value,
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        observeImpl(
            owner: self,
            options: options,
            duplicateFilter: options.contains(.removeDuplicates) ? makeEquatableDuplicateFilterSendable() : nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: makeAnyKeyPathsValueGetter(keyPaths, of: value),
            onChange: makeOnChangeAdapter(onChange)
        )
    }

    @discardableResult
    func observeTask<Value: Sendable>(
        _ keyPaths: sending [PartialKeyPath<Self>],
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        of value: @escaping @Sendable (Self) -> Value,
        @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending Value) async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates requires Value to conform to Equatable")
        }

        return observeTaskImpl(
            owner: self,
            options: options,
            duplicateFilter: nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: makeAnyKeyPathsValueGetter(keyPaths, of: value),
            task: task
        )
    }

    @discardableResult
    func observeTask<Value: Sendable & Equatable>(
        _ keyPaths: sending [PartialKeyPath<Self>],
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        of value: @escaping @Sendable (Self) -> Value,
        @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending Value) async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        observeTaskImpl(
            owner: self,
            options: options,
            duplicateFilter: options.contains(.removeDuplicates) ? makeEquatableDuplicateFilterSendable() : nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: makeAnyKeyPathsValueGetter(keyPaths, of: value),
            task: task
        )
    }
}

public extension Observable where Self: AnyObject {
    @discardableResult
    func observe<Value>(
        _ keyPath: sending KeyPath<Self, Value>,
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates requires Value to conform to Equatable")
        }

        let getter = makeKeyPathGetter(keyPath)
        let producerIsolation = getter.isolation ?? isolation
        preconditionNonSendableSameIsolation(
            producerIsolation: producerIsolation,
            consumerIsolation: onChange.isolation,
            operation: "observe(_:options:clock:onChange:isolation:)"
        )

        return observeImplNonSendable(
            owner: self,
            options: options,
            duplicateFilter: nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: getter,
            onChange: makeNonSendableOnChangeAdapter(onChange)
        )
    }

    @discardableResult
    func observe<Value>(
        _ keyPath: sending KeyPath<Self, Value>,
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable () -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates requires Value to conform to Equatable")
        }

        let getter = makeKeyPathGetter(keyPath)
        let producerIsolation = getter.isolation ?? isolation
        preconditionNonSendableSameIsolation(
            producerIsolation: producerIsolation,
            consumerIsolation: onChange.isolation,
            operation: "observe(_:options:clock:onChange:isolation:)"
        )

        return observeImplNonSendable(
            owner: self,
            options: options,
            duplicateFilter: nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: getter,
            onChange: makeNonSendableVoidOnChangeAdapter(onChange)
        )
    }

    @discardableResult
    func observe<Value: Equatable>(
        _ keyPath: sending KeyPath<Self, Value>,
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        let getter = makeKeyPathGetter(keyPath)
        let producerIsolation = getter.isolation ?? isolation
        preconditionNonSendableSameIsolation(
            producerIsolation: producerIsolation,
            consumerIsolation: onChange.isolation,
            operation: "observe(_:options:clock:onChange:isolation:)"
        )

        return observeImplNonSendable(
            owner: self,
            options: options,
            duplicateFilter: options.contains(.removeDuplicates) ? makeEquatableDuplicateFilterNonSendable() : nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: getter,
            onChange: makeNonSendableOnChangeAdapter(onChange)
        )
    }

    @discardableResult
    func observe<Value: Equatable>(
        _ keyPath: sending KeyPath<Self, Value>,
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable () -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        let getter = makeKeyPathGetter(keyPath)
        let producerIsolation = getter.isolation ?? isolation
        preconditionNonSendableSameIsolation(
            producerIsolation: producerIsolation,
            consumerIsolation: onChange.isolation,
            operation: "observe(_:options:clock:onChange:isolation:)"
        )

        return observeImplNonSendable(
            owner: self,
            options: options,
            duplicateFilter: options.contains(.removeDuplicates) ? makeEquatableDuplicateFilterNonSendable() : nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: getter,
            onChange: makeNonSendableVoidOnChangeAdapter(onChange)
        )
    }

    @discardableResult
    func observeTask<Value>(
        _ keyPath: sending KeyPath<Self, Value>,
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending Value) async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates requires Value to conform to Equatable")
        }

        let getter = makeKeyPathGetter(keyPath)
        let producerIsolation = getter.isolation ?? isolation
        preconditionNonSendableSameIsolation(
            producerIsolation: producerIsolation,
            consumerIsolation: task.isolation,
            operation: "observeTask(_:options:clock:task:isolation:)"
        )

        return observeTaskImplNonSendable(
            owner: self,
            options: options,
            duplicateFilter: nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: getter,
            task: makeNonSendableTaskAdapter(task)
        )
    }

    @discardableResult
    func observeTask<Value>(
        _ keyPath: sending KeyPath<Self, Value>,
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext task: @escaping @isolated(any) @Sendable () async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates requires Value to conform to Equatable")
        }

        let getter = makeKeyPathGetter(keyPath)
        let producerIsolation = getter.isolation ?? isolation
        preconditionNonSendableSameIsolation(
            producerIsolation: producerIsolation,
            consumerIsolation: task.isolation,
            operation: "observeTask(_:options:clock:task:isolation:)"
        )

        return observeTaskImplNonSendable(
            owner: self,
            options: options,
            duplicateFilter: nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: getter,
            task: makeNonSendableVoidTaskAdapter(task)
        )
    }

    @discardableResult
    func observeTask<Value: Equatable>(
        _ keyPath: sending KeyPath<Self, Value>,
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending Value) async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        let getter = makeKeyPathGetter(keyPath)
        let producerIsolation = getter.isolation ?? isolation
        preconditionNonSendableSameIsolation(
            producerIsolation: producerIsolation,
            consumerIsolation: task.isolation,
            operation: "observeTask(_:options:clock:task:isolation:)"
        )

        return observeTaskImplNonSendable(
            owner: self,
            options: options,
            duplicateFilter: options.contains(.removeDuplicates) ? makeEquatableDuplicateFilterNonSendable() : nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: getter,
            task: makeNonSendableTaskAdapter(task)
        )
    }

    @discardableResult
    func observeTask<Value: Equatable>(
        _ keyPath: sending KeyPath<Self, Value>,
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext task: @escaping @isolated(any) @Sendable () async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        let getter = makeKeyPathGetter(keyPath)
        let producerIsolation = getter.isolation ?? isolation
        preconditionNonSendableSameIsolation(
            producerIsolation: producerIsolation,
            consumerIsolation: task.isolation,
            operation: "observeTask(_:options:clock:task:isolation:)"
        )

        return observeTaskImplNonSendable(
            owner: self,
            options: options,
            duplicateFilter: options.contains(.removeDuplicates) ? makeEquatableDuplicateFilterNonSendable() : nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: getter,
            task: makeNonSendableVoidTaskAdapter(task)
        )
    }

    @discardableResult
    func observe<Value>(
        _ keyPaths: sending [PartialKeyPath<Self>],
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        of value: @escaping @Sendable (Self) -> Value,
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates requires Value to conform to Equatable")
        }

        let projection = makeAnyKeyPathsValueGetter(keyPaths, of: value)
        let producerIsolation = projection.isolation ?? isolation
        preconditionNonSendableSameIsolation(
            producerIsolation: producerIsolation,
            consumerIsolation: onChange.isolation,
            operation: "observe(_:options:clock:of:onChange:isolation:)"
        )

        return observeImplNonSendable(
            owner: self,
            options: options,
            duplicateFilter: nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: projection,
            onChange: makeNonSendableOnChangeAdapter(onChange)
        )
    }

    @discardableResult
    func observe<Value: Equatable>(
        _ keyPaths: sending [PartialKeyPath<Self>],
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        of value: @escaping @Sendable (Self) -> Value,
        @_inheritActorContext onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        let projection = makeAnyKeyPathsValueGetter(keyPaths, of: value)
        let producerIsolation = projection.isolation ?? isolation
        preconditionNonSendableSameIsolation(
            producerIsolation: producerIsolation,
            consumerIsolation: onChange.isolation,
            operation: "observe(_:options:clock:of:onChange:isolation:)"
        )

        return observeImplNonSendable(
            owner: self,
            options: options,
            duplicateFilter: options.contains(.removeDuplicates) ? makeEquatableDuplicateFilterNonSendable() : nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: projection,
            onChange: makeNonSendableOnChangeAdapter(onChange)
        )
    }

    @discardableResult
    func observeTask<Value>(
        _ keyPaths: sending [PartialKeyPath<Self>],
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        of value: @escaping @Sendable (Self) -> Value,
        @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending Value) async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates requires Value to conform to Equatable")
        }

        let projection = makeAnyKeyPathsValueGetter(keyPaths, of: value)
        let producerIsolation = projection.isolation ?? isolation
        preconditionNonSendableSameIsolation(
            producerIsolation: producerIsolation,
            consumerIsolation: task.isolation,
            operation: "observeTask(_:options:clock:of:task:isolation:)"
        )

        return observeTaskImplNonSendable(
            owner: self,
            options: options,
            duplicateFilter: nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: projection,
            task: makeNonSendableTaskAdapter(task)
        )
    }

    @discardableResult
    func observeTask<Value: Equatable>(
        _ keyPaths: sending [PartialKeyPath<Self>],
        options: ObservationOptions = [],
        clock: any Clock<Duration> = ContinuousClock(),
        of value: @escaping @Sendable (Self) -> Value,
        @_inheritActorContext task: @escaping @isolated(any) @Sendable (sending Value) async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) -> ObservationHandle {
        let projection = makeAnyKeyPathsValueGetter(keyPaths, of: value)
        let producerIsolation = projection.isolation ?? isolation
        preconditionNonSendableSameIsolation(
            producerIsolation: producerIsolation,
            consumerIsolation: task.isolation,
            operation: "observeTask(_:options:clock:of:task:isolation:)"
        )

        return observeTaskImplNonSendable(
            owner: self,
            options: options,
            duplicateFilter: options.contains(.removeDuplicates) ? makeEquatableDuplicateFilterNonSendable() : nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock,
            isolation: isolation,
            of: projection,
            task: makeNonSendableTaskAdapter(task)
        )
    }
}

// KeyPath / PartialKeyPath are immutable metadata; wrapping allows safe capture in @Sendable closures.
private struct _UncheckedSendableKeyPath<Owner: AnyObject, Value>: @unchecked Sendable {
    let keyPath: KeyPath<Owner, Value>
}

private struct _UncheckedSendablePartialKeyPaths<Owner: AnyObject>: @unchecked Sendable {
    let keyPaths: [PartialKeyPath<Owner>]
}

private struct _UncheckedSendableTypeMarker<Value>: @unchecked Sendable {
    let valueType: Value.Type
}

func hasSameObservationIsolation(
    _ lhs: (any Actor)?,
    _ rhs: (any Actor)?
) -> Bool {
    guard let lhs, let rhs else {
        return false
    }
    return ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
}

private func preconditionNonSendableSameIsolation(
    producerIsolation: (any Actor)?,
    consumerIsolation: (any Actor)?,
    operation: StaticString
) {
    precondition(
        hasSameObservationIsolation(producerIsolation, consumerIsolation),
        "\(operation): non-Sendable observation requires producer and consumer closures to share the same actor isolation"
    )
}

private func makeKeyPathGetter<Owner: AnyObject, Value>(
    _ keyPath: sending KeyPath<Owner, Value>
) -> @isolated(any) @Sendable (Owner) -> Value {
    let keyPath = _UncheckedSendableKeyPath(keyPath: keyPath)
    return { owner in
        owner[keyPath: keyPath.keyPath]
    }
}

private func makeAnyKeyPathsTriggerGetter<Owner: AnyObject>(
    _ keyPaths: sending [PartialKeyPath<Owner>]
) -> @isolated(any) @Sendable (Owner) -> Void {
    let keyPaths = _UncheckedSendablePartialKeyPaths(keyPaths: keyPaths)
    return { owner in
        for keyPath in keyPaths.keyPaths {
            _ = owner[keyPath: keyPath]
        }
    }
}

private func makeAnyKeyPathsValueGetter<Owner: AnyObject, Value>(
    _ keyPaths: sending [PartialKeyPath<Owner>],
    of value: @escaping @Sendable (Owner) -> Value
) -> @isolated(any) @Sendable (Owner) -> Value {
    let keyPaths = _UncheckedSendablePartialKeyPaths(keyPaths: keyPaths)
    return { owner in
        for keyPath in keyPaths.keyPaths {
            _ = owner[keyPath: keyPath]
        }
        return value(owner)
    }
}

private func makeOnChangeAdapter<Value>(
    _ onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void
) -> @isolated(any) @Sendable (sending Value) async -> Void {
    { value in
        await onChange(value)
    }
}

private func makeEquatableDuplicateFilterSendable<Value: Sendable & Equatable>() -> @Sendable (Value, Value) -> Bool {
    { lhs, rhs in
        lhs == rhs
    }
}

private func makeEquatableDuplicateFilterNonSendable<Value: Equatable>() -> @Sendable (Value, Value) -> Bool {
    let comparator: (Value, Value) -> Bool = { lhs, rhs in
        lhs == rhs
    }
    return unsafe unsafeBitCast(comparator, to: (@Sendable (Value, Value) -> Bool).self)
}

private func makeNonSendableOnChangeAdapter<Value>(
    _ onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void
) -> @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void {
    { boxedValue in
        await onChange(boxedValue.value)
    }
}

private func makeNonSendableVoidOnChangeAdapter<Value>(
    _ onChange: @escaping @isolated(any) @Sendable () -> Void
) -> @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void {
    let marker = _UncheckedSendableTypeMarker(valueType: Value.self)
    return { _ in
        _ = marker
        await onChange()
    }
}

private func makeNonSendableTaskAdapter<Value>(
    _ task: @escaping @isolated(any) @Sendable (sending Value) async -> Void
) -> @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void {
    { boxedValue in
        await task(boxedValue.value)
    }
}

private func makeNonSendableVoidTaskAdapter<Value>(
    _ task: @escaping @isolated(any) @Sendable () async -> Void
) -> @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void {
    let marker = _UncheckedSendableTypeMarker(valueType: Value.self)
    return { _ in
        _ = marker
        await task()
    }
}

enum ResolvedBackend: Sendable {
    case native
    case legacy
}

private final class ObservationBridgeStreamFactory<Value>: Sendable {
    let makeStream: @Sendable () -> AsyncStream<Value>

    init(makeStream: @escaping @Sendable () -> AsyncStream<Value>) {
        self.makeStream = makeStream
    }
}

private struct SendableObservationBridgeStreamBuilder<Value: Sendable>: Sendable {
    let options: ObservationOptions
    let observe: @isolated(any) @Sendable () -> Value
    let capturedIsolation: (any Actor)?
    let duplicateFilter: (@Sendable (Value, Value) -> Bool)?
    let rateLimit: ObservationRateLimit?
    let rateLimitClock: any Clock<Duration>

    func makeStream() -> AsyncStream<Value> {
        makeObservationStreamFromCapturedIsolation(
            options: options,
            observe,
            capturedIsolation: capturedIsolation,
            duplicateFilter: duplicateFilter,
            rateLimit: rateLimit,
            rateLimitClock: rateLimitClock
        )
    }
}

private struct ObservationBridgeStreamBuilder<Value>: Sendable {
    let options: ObservationOptions
    let observe: @isolated(any) @Sendable () -> Value
    let capturedIsolation: (any Actor)?
    let duplicateFilter: (@Sendable (Value, Value) -> Bool)?
    let rateLimit: ObservationRateLimit?
    let rateLimitClock: any Clock<Duration>

    func makeStream() -> AsyncStream<Value> {
        makeObservationStreamFromCapturedIsolation(
            options: options,
            observe,
            capturedIsolation: capturedIsolation,
            duplicateFilter: duplicateFilter,
            rateLimit: rateLimit,
            rateLimitClock: rateLimitClock
        )
    }
}

func makeObservationStream<Value: Sendable>(
    options: ObservationOptions = [],
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isolation: isolated (any Actor)? = #isolation,
    duplicateFilter: (@Sendable (Value, Value) -> Bool)? = nil,
    rateLimit: ObservationRateLimit? = nil,
    rateLimitClock: any Clock<Duration> = ContinuousClock()
) -> AsyncStream<Value> {
    let stream = makeRawObservationStream(
        options: options,
        observe,
        isolation: observe.isolation ?? isolation
    )
    let streamWithRateLimit: AsyncStream<Value>
    if let rateLimit {
        streamWithRateLimit = makeRateLimitedValueStream(
            stream,
            rateLimit: rateLimit,
            rateLimitClock: rateLimitClock
        )
    } else {
        streamWithRateLimit = stream
    }

    return makeDuplicateFilteredStream(
        streamWithRateLimit,
        isDuplicate: duplicateFilter
    )
}

private func makeObservationStreamFromCapturedIsolation<Value: Sendable>(
    options: ObservationOptions = [],
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    capturedIsolation: (any Actor)?,
    duplicateFilter: (@Sendable (Value, Value) -> Bool)? = nil,
    rateLimit: ObservationRateLimit? = nil,
    rateLimitClock: any Clock<Duration> = ContinuousClock()
) -> AsyncStream<Value> {
    let stream = makeRawObservationStream(
        options: options,
        observe,
        isolation: observe.isolation ?? capturedIsolation
    )
    let streamWithRateLimit: AsyncStream<Value>
    if let rateLimit {
        streamWithRateLimit = makeRateLimitedValueStream(
            stream,
            rateLimit: rateLimit,
            rateLimitClock: rateLimitClock
        )
    } else {
        streamWithRateLimit = stream
    }

    return makeDuplicateFilteredStream(
        streamWithRateLimit,
        isDuplicate: duplicateFilter
    )
}

func makeObservationStream<Value>(
    options: ObservationOptions = [],
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isolation: isolated (any Actor)? = #isolation,
    duplicateFilter: (@Sendable (Value, Value) -> Bool)? = nil,
    rateLimit: ObservationRateLimit? = nil,
    rateLimitClock: any Clock<Duration> = ContinuousClock()
) -> AsyncStream<Value> {
    _ = options

    let boxedObserve: @isolated(any) @Sendable () -> _UncheckedSendableValueBox<Value> = {
        _UncheckedSendableValueBox(
            _ObservationBridgeLegacy.legacyEvaluateObservedValue(
                isolation: #isolation,
                observe: observe
            )
        )
    }
    let boxedDuplicateFilter: (@Sendable (_UncheckedSendableValueBox<Value>, _UncheckedSendableValueBox<Value>) -> Bool)?
    if let duplicateFilter {
        boxedDuplicateFilter = { lhs, rhs in
            duplicateFilter(lhs.value, rhs.value)
        }
    } else {
        boxedDuplicateFilter = nil
    }

    let boxedStream = makeLegacyObservationStream(
        boxedObserve,
        isDuplicate: nil,
        isolation: observe.isolation ?? isolation
    )
    let boxedStreamWithRateLimit: AsyncStream<_UncheckedSendableValueBox<Value>>
    if let rateLimit {
        boxedStreamWithRateLimit = makeRateLimitedValueStream(
            boxedStream,
            rateLimit: rateLimit,
            rateLimitClock: rateLimitClock
        )
    } else {
        boxedStreamWithRateLimit = boxedStream
    }

    let boxedFilteredStream = makeDuplicateFilteredStream(
        boxedStreamWithRateLimit,
        isDuplicate: boxedDuplicateFilter
    )

    let stream = AsyncStream<Value> { continuation in
        let task = Task {
            for await boxedValue in boxedFilteredStream {
                if Task.isCancelled {
                    break
                }
                continuation.yield(boxedValue.value)
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
    return stream
}

private func makeObservationStreamFromCapturedIsolation<Value>(
    options: ObservationOptions = [],
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    capturedIsolation: (any Actor)?,
    duplicateFilter: (@Sendable (Value, Value) -> Bool)? = nil,
    rateLimit: ObservationRateLimit? = nil,
    rateLimitClock: any Clock<Duration> = ContinuousClock()
) -> AsyncStream<Value> {
    _ = options

    let boxedObserve: @isolated(any) @Sendable () -> _UncheckedSendableValueBox<Value> = {
        let resolvedIsolation = observe.isolation ?? capturedIsolation
        if let resolvedIsolation {
            return resolvedIsolation.assumeIsolated { _ in
                _UncheckedSendableValueBox(
                    _ObservationBridgeLegacy.legacyEvaluateObservedValue(
                        observe: observe
                    )
                )
            }
        }

        return _UncheckedSendableValueBox(
            _ObservationBridgeLegacy.legacyEvaluateObservedValue(
                observe: observe
            )
        )
    }
    let boxedDuplicateFilter: (@Sendable (_UncheckedSendableValueBox<Value>, _UncheckedSendableValueBox<Value>) -> Bool)?
    if let duplicateFilter {
        boxedDuplicateFilter = { lhs, rhs in
            duplicateFilter(lhs.value, rhs.value)
        }
    } else {
        boxedDuplicateFilter = nil
    }

    let boxedStream = makeLegacyObservationStream(
        boxedObserve,
        isDuplicate: nil,
        isolation: observe.isolation ?? capturedIsolation
    )
    let boxedStreamWithRateLimit: AsyncStream<_UncheckedSendableValueBox<Value>>
    if let rateLimit {
        boxedStreamWithRateLimit = makeRateLimitedValueStream(
            boxedStream,
            rateLimit: rateLimit,
            rateLimitClock: rateLimitClock
        )
    } else {
        boxedStreamWithRateLimit = boxedStream
    }

    let boxedFilteredStream = makeDuplicateFilteredStream(
        boxedStreamWithRateLimit,
        isDuplicate: boxedDuplicateFilter
    )

    let stream = AsyncStream<Value> { continuation in
        let task = Task {
            for await boxedValue in boxedFilteredStream {
                if Task.isCancelled {
                    break
                }
                continuation.yield(boxedValue.value)
            }
            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
    return stream
}

private func makeRawObservationStream<Value: Sendable>(
    options: ObservationOptions = [],
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isolation: (any Actor)?
) -> AsyncStream<Value> {
    switch resolveBackend(options: options) {
    case .legacy:
        return makeLegacyObservationStream(
            observe,
            isDuplicate: nil,
            isolation: isolation
        )
    case .native:
        if #available(iOS 26.0, macOS 26.0, *) {
            return makeNativeStream(
                observe,
                isolation: isolation
            )
        }
        return makeLegacyObservationStream(
            observe,
            isDuplicate: nil,
            isolation: isolation
        )
    }
}

private enum _ObservationStreamPrevious<Value> {
    case none
    case value(Value)
}

private func makeDuplicateFilteredStream<Value: Sendable>(
    _ source: AsyncStream<Value>,
    isDuplicate: (@Sendable (Value, Value) -> Bool)?
) -> AsyncStream<Value> {
    AsyncStream<Value> { continuation in
        let task = Task {
            var previousValue: _ObservationStreamPrevious<Value> = .none

            for await value in source {
                if Task.isCancelled {
                    break
                }

                if case let .value(previous) = previousValue,
                   let isDuplicate,
                   isDuplicate(previous, value)
                {
                    continue
                }

                previousValue = .value(value)
                continuation.yield(value)
            }

            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

func resolveBackend(options: ObservationOptions) -> ResolvedBackend {
    if options.forcesLegacyBackend {
        return .legacy
    }

    if #available(iOS 26.0, macOS 26.0, *) {
        return .native
    }
    return .legacy
}

@available(iOS 26.0, macOS 26.0, *)
private func makeNativeStream<Value: Sendable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isolation: (any Actor)?
) -> AsyncStream<Value> {
    AsyncStream<Value> { continuation in
        let task = Task {
            await drainNativeObservationValues(
                observe: observe,
                isolation: isolation,
                continuation: continuation
            )

            continuation.finish()
        }

        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
private func drainNativeObservationValues<Value: Sendable>(
    observe: @escaping @isolated(any) @Sendable () -> Value,
    isolation: isolated (any Actor)?,
    continuation: AsyncStream<Value>.Continuation
) async {
    let observations = Observations(observe)
    var iterator = observations.makeAsyncIterator()

    while let value = await iterator.next(isolation: isolation) {
        if Task.isCancelled {
            break
        }
        continuation.yield(value)
    }
}

public struct ObservationBridge<Value>: AsyncSequence {
    public typealias Element = Value

    public struct Iterator: AsyncIteratorProtocol {
        private var base: AsyncStream<Value>.Iterator

        fileprivate init(base: AsyncStream<Value>.Iterator) {
            self.base = base
        }

        public mutating func next() async -> Value? {
            await base.next()
        }
    }

    private let streamFactory: ObservationBridgeStreamFactory<Value>

    fileprivate init(streamFactory: @escaping @Sendable () -> AsyncStream<Value>) {
        self.streamFactory = ObservationBridgeStreamFactory(makeStream: streamFactory)
    }

    public init(
        options: ObservationOptions,
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        let constructionIsolation: (any Actor)? = #isolation

        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates requires Value to conform to Equatable")
        }

        let builder = ObservationBridgeStreamBuilder(
            options: options,
            observe: observe,
            capturedIsolation: constructionIsolation,
            duplicateFilter: nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock
        )
        self.init(streamFactory: builder.makeStream)
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: streamFactory.makeStream().makeAsyncIterator())
    }
}

extension ObservationBridge: Sendable where Value: Sendable {}

public extension ObservationBridge where Value: Sendable {
    init(
        options: ObservationOptions,
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        let constructionIsolation: (any Actor)? = #isolation

        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates requires Value to conform to Equatable")
        }

        let builder = SendableObservationBridgeStreamBuilder(
            options: options,
            observe: observe,
            capturedIsolation: constructionIsolation,
            duplicateFilter: nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock
        )
        self.init(streamFactory: builder.makeStream)
    }
}

public extension ObservationBridge where Value: Equatable {
    init(
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        self.init(
            options: [.removeDuplicates],
            observe
        )
    }

    init(
        options: ObservationOptions,
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        let constructionIsolation: (any Actor)? = #isolation

        let builder = ObservationBridgeStreamBuilder(
            options: options,
            observe: observe,
            capturedIsolation: constructionIsolation,
            duplicateFilter: options.contains(.removeDuplicates) ? makeEquatableDuplicateFilterNonSendable() : nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock
        )
        self.init(streamFactory: builder.makeStream)
    }
}

public extension ObservationBridge where Value: Sendable & Equatable {
    init(
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        self.init(
            options: [.removeDuplicates],
            observe
        )
    }

    init(
        options: ObservationOptions,
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        let constructionIsolation: (any Actor)? = #isolation

        let builder = SendableObservationBridgeStreamBuilder(
            options: options,
            observe: observe,
            capturedIsolation: constructionIsolation,
            duplicateFilter: options.contains(.removeDuplicates) ? makeEquatableDuplicateFilterSendable() : nil,
            rateLimit: options.rateLimitForObservation,
            rateLimitClock: clock
        )
        self.init(streamFactory: builder.makeStream)
    }
}

public func makeObservationBridgeStream<Value: Equatable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationBridge<Value> {
    ObservationBridge(observe)
}

public func makeObservationBridgeStream<Value: Sendable & Equatable>(
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationBridge<Value> {
    ObservationBridge(observe)
}

public func makeObservationBridgeStream<Value>(
    options: ObservationOptions,
    clock: any Clock<Duration> = ContinuousClock(),
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationBridge<Value> {
    ObservationBridge(
        options: options,
        clock: clock,
        observe
    )
}

public func makeObservationBridgeStream<Value: Sendable>(
    options: ObservationOptions,
    clock: any Clock<Duration> = ContinuousClock(),
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationBridge<Value> {
    ObservationBridge(
        options: options,
        clock: clock,
        observe
    )
}

public func makeObservationBridgeStream<Value: Equatable>(
    options: ObservationOptions,
    clock: any Clock<Duration> = ContinuousClock(),
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationBridge<Value> {
    ObservationBridge(
        options: options,
        clock: clock,
        observe
    )
}

public func makeObservationBridgeStream<Value: Sendable & Equatable>(
    options: ObservationOptions,
    clock: any Clock<Duration> = ContinuousClock(),
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
) -> ObservationBridge<Value> {
    ObservationBridge(
        options: options,
        clock: clock,
        observe
    )
}
