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

public struct ObservationOptions: OptionSet, Sendable {
    private static let removeDuplicatesFlag: UInt64 = 1 << 0
    private static let debounceFlag: UInt64 = 1 << 1
    private static let delayedFirstFlag: UInt64 = 1 << 2
    private static let tolerancePresentFlag: UInt64 = 1 << 3
    private static let legacyBackendFlag: UInt64 = 1 << 61
    private static let conflictingDebounceFlag: UInt64 = 1 << 60
    private static let debouncePayloadBitWidth: UInt64 = 28
    private static let debounceIntervalShift: UInt64 = 4
    private static let debounceToleranceShift: UInt64 = debounceIntervalShift + debouncePayloadBitWidth
    private static let debouncePayloadMask: UInt64 = (1 << debouncePayloadBitWidth) - 1
    private static let debounceIntervalMask: UInt64 = debouncePayloadMask << debounceIntervalShift
    private static let debounceToleranceMask: UInt64 = debouncePayloadMask << debounceToleranceShift
    private static let membershipMask: UInt64 = removeDuplicatesFlag | debounceFlag | legacyBackendFlag

    public let rawValue: UInt64
    private let debounceConfiguration: ObservationDebounce?
    private let hasConflictingDebounce: Bool

    public init() {
        rawValue = 0
        debounceConfiguration = nil
        hasConflictingDebounce = false
    }

    public init(rawValue: UInt64) {
        let removeDuplicates = (rawValue & Self.removeDuplicatesFlag) != 0
        let usesLegacyBackend = (rawValue & Self.legacyBackendFlag) != 0
        let hasConflictingDebounce = (rawValue & Self.conflictingDebounceFlag) != 0
        let debounceConfiguration = hasConflictingDebounce ? nil : Self.decodeDebounceConfiguration(from: rawValue)
        self.rawValue = Self.encodeRawValue(
            removeDuplicates: removeDuplicates,
            usesLegacyBackend: usesLegacyBackend,
            debounceConfiguration: debounceConfiguration,
            hasConflictingDebounce: hasConflictingDebounce
        )
        self.debounceConfiguration = debounceConfiguration
        self.hasConflictingDebounce = hasConflictingDebounce
    }

    private init(
        removeDuplicates: Bool,
        usesLegacyBackend: Bool,
        debounceConfiguration: ObservationDebounce?,
        hasConflictingDebounce: Bool = false
    ) {
        let normalizedDebounceConfiguration = hasConflictingDebounce
            ? nil
            : Self.normalizeDebounceConfiguration(debounceConfiguration)
        self.rawValue = Self.encodeRawValue(
            removeDuplicates: removeDuplicates,
            usesLegacyBackend: usesLegacyBackend,
            debounceConfiguration: normalizedDebounceConfiguration,
            hasConflictingDebounce: hasConflictingDebounce
        )
        self.debounceConfiguration = normalizedDebounceConfiguration
        self.hasConflictingDebounce = hasConflictingDebounce
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

    public static func debounce(_ configuration: ObservationDebounce) -> ObservationOptions {
        ObservationOptions(removeDuplicates: false, usesLegacyBackend: false, debounceConfiguration: configuration)
    }

    public var debounce: ObservationDebounce? {
        debounceConfiguration
    }

    var hasDebounceConflict: Bool {
        hasConflictingDebounce
    }

    var debounceForObservation: ObservationDebounce? {
        guard !hasDebounceConflict else {
            preconditionFailure("Conflicting debounce options are not supported when starting observation")
        }
        return debounceConfiguration
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
        if member.hasConflictingDebounce {
            return hasConflictingDebounce
        }
        guard let memberDebounceConfiguration = member.debounceConfiguration else {
            return true
        }
        return debounceConfiguration == memberDebounceConfiguration
    }

    public func union(_ other: ObservationOptions) -> ObservationOptions {
        let removeDuplicates = (rawValue & Self.removeDuplicatesFlag) != 0 || (other.rawValue & Self.removeDuplicatesFlag) != 0
        let usesLegacyBackend = (rawValue & Self.legacyBackendFlag) != 0 || (other.rawValue & Self.legacyBackendFlag) != 0
        let mergedDebounce = Self.mergeDebounce(
            lhs: debounceConfiguration,
            lhsConflicting: hasConflictingDebounce,
            rhs: other.debounceConfiguration,
            rhsConflicting: other.hasConflictingDebounce
        )
        return ObservationOptions(
            removeDuplicates: removeDuplicates,
            usesLegacyBackend: usesLegacyBackend,
            debounceConfiguration: mergedDebounce.configuration,
            hasConflictingDebounce: mergedDebounce.hasConflict
        )
    }

    public mutating func formUnion(_ other: ObservationOptions) {
        self = union(other)
    }

    public func intersection(_ other: ObservationOptions) -> ObservationOptions {
        let removeDuplicates = (rawValue & Self.removeDuplicatesFlag) != 0 && (other.rawValue & Self.removeDuplicatesFlag) != 0
        let usesLegacyBackend = (rawValue & Self.legacyBackendFlag) != 0 && (other.rawValue & Self.legacyBackendFlag) != 0
        let intersectedConflict = hasConflictingDebounce && other.hasConflictingDebounce
        let intersectedDebounce = intersectedConflict ? nil : (debounceConfiguration == other.debounceConfiguration ? debounceConfiguration : nil)
        return ObservationOptions(
            removeDuplicates: removeDuplicates,
            usesLegacyBackend: usesLegacyBackend,
            debounceConfiguration: intersectedDebounce,
            hasConflictingDebounce: intersectedConflict
        )
    }

    public mutating func formIntersection(_ other: ObservationOptions) {
        self = intersection(other)
    }

    public func symmetricDifference(_ other: ObservationOptions) -> ObservationOptions {
        let removeDuplicates = ((rawValue & Self.removeDuplicatesFlag) != 0) != ((other.rawValue & Self.removeDuplicatesFlag) != 0)
        let usesLegacyBackend = ((rawValue & Self.legacyBackendFlag) != 0) != ((other.rawValue & Self.legacyBackendFlag) != 0)
        let resultingConflict = hasConflictingDebounce != other.hasConflictingDebounce
        let resultingDebounce: ObservationDebounce?
        if resultingConflict {
            resultingDebounce = nil
        } else {
            switch (debounceConfiguration, other.debounceConfiguration) {
            case (nil, nil):
                resultingDebounce = nil
            case let (lhs?, nil):
                resultingDebounce = lhs
            case let (nil, rhs?):
                resultingDebounce = rhs
            case (.some, .some):
                resultingDebounce = nil
            }
        }

        return ObservationOptions(
            removeDuplicates: removeDuplicates,
            usesLegacyBackend: usesLegacyBackend,
            debounceConfiguration: resultingDebounce,
            hasConflictingDebounce: resultingConflict
        )
    }

    public mutating func formSymmetricDifference(_ other: ObservationOptions) {
        self = symmetricDifference(other)
    }

    public func subtracting(_ other: ObservationOptions) -> ObservationOptions {
        let removeDuplicates = (rawValue & Self.removeDuplicatesFlag) != 0 && (other.rawValue & Self.removeDuplicatesFlag) == 0
        let usesLegacyBackend = (rawValue & Self.legacyBackendFlag) != 0 && (other.rawValue & Self.legacyBackendFlag) == 0
        let resultingConflict: Bool
        let resultingDebounce: ObservationDebounce?
        if hasConflictingDebounce {
            resultingConflict = !other.hasConflictingDebounce
            resultingDebounce = nil
        } else {
            resultingConflict = false
            resultingDebounce = debounceConfiguration == other.debounceConfiguration ? nil : debounceConfiguration
        }
        return ObservationOptions(
            removeDuplicates: removeDuplicates,
            usesLegacyBackend: usesLegacyBackend,
            debounceConfiguration: resultingDebounce,
            hasConflictingDebounce: resultingConflict
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
        debounceConfiguration: ObservationDebounce?,
        hasConflictingDebounce: Bool
    ) -> UInt64 {
        var rawValue: UInt64 = removeDuplicates ? removeDuplicatesFlag : 0
        if usesLegacyBackend {
            rawValue |= legacyBackendFlag
        }
        if hasConflictingDebounce {
            rawValue |= conflictingDebounceFlag
            return rawValue
        }
        guard let debounceConfiguration else {
            return rawValue
        }

        rawValue |= debounceFlag
        rawValue |= encodeDebouncePayload(debounceConfiguration)
        return rawValue
    }

    private static func decodeDebounceConfiguration(from rawValue: UInt64) -> ObservationDebounce? {
        guard (rawValue & debounceFlag) != 0 else {
            return nil
        }

        let mode: ObservationDebounceMode = (rawValue & delayedFirstFlag) != 0 ? .delayedFirst : .immediateFirst
        let intervalMilliseconds = (rawValue & debounceIntervalMask) >> debounceIntervalShift
        let interval = Duration.milliseconds(Int64(intervalMilliseconds))

        let tolerance: Duration?
        if (rawValue & tolerancePresentFlag) != 0 {
            let toleranceMilliseconds = (rawValue & debounceToleranceMask) >> debounceToleranceShift
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

    private static func normalizeDebounceConfiguration(_ debounceConfiguration: ObservationDebounce?) -> ObservationDebounce? {
        guard let debounceConfiguration else {
            return nil
        }
        let encodedRawValue = debounceFlag | encodeDebouncePayload(debounceConfiguration)
        return decodeDebounceConfiguration(from: encodedRawValue)
    }

    private static func encodeDebouncePayload(_ debounceConfiguration: ObservationDebounce) -> UInt64 {
        let intervalMilliseconds = encodeMilliseconds(
            debounceConfiguration.interval,
            parameter: "interval"
        )

        var payload = intervalMilliseconds << debounceIntervalShift
        if debounceConfiguration.mode == .delayedFirst {
            payload |= delayedFirstFlag
        }

        if let tolerance = debounceConfiguration.tolerance {
            let toleranceMilliseconds = encodeMilliseconds(
                tolerance,
                parameter: "tolerance"
            )
            payload |= tolerancePresentFlag
            payload |= toleranceMilliseconds << debounceToleranceShift
        }

        return payload
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
            totalMilliseconds <= debouncePayloadMask,
            "\(parameter) is too large to encode"
        )
        return totalMilliseconds
    }

    private struct DebounceMergeResult {
        let configuration: ObservationDebounce?
        let hasConflict: Bool
    }

    private static func mergeDebounce(
        lhs: ObservationDebounce?,
        lhsConflicting: Bool,
        rhs: ObservationDebounce?,
        rhsConflicting: Bool
    ) -> DebounceMergeResult {
        if lhsConflicting || rhsConflicting {
            return DebounceMergeResult(configuration: nil, hasConflict: true)
        }

        switch (lhs, rhs) {
        case (nil, nil):
            return DebounceMergeResult(configuration: nil, hasConflict: false)
        case let (lhs?, nil):
            return DebounceMergeResult(configuration: lhs, hasConflict: false)
        case let (nil, rhs?):
            return DebounceMergeResult(configuration: rhs, hasConflict: false)
        case let (lhs?, rhs?):
            if lhs == rhs {
                return DebounceMergeResult(configuration: lhs, hasConflict: false)
            }
            return DebounceMergeResult(configuration: nil, hasConflict: true)
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
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            duplicateFilter: options.contains(.removeDuplicates) ? { @Sendable lhs, rhs in lhs == rhs } : nil,
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            duplicateFilter: options.contains(.removeDuplicates) ? { @Sendable lhs, rhs in lhs == rhs } : nil,
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            duplicateFilter: options.contains(.removeDuplicates) ? { @Sendable lhs, rhs in lhs == rhs } : nil,
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            duplicateFilter: options.contains(.removeDuplicates) ? { @Sendable lhs, rhs in lhs == rhs } : nil,
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            duplicateFilter: options.contains(.removeDuplicates) ? { @Sendable lhs, rhs in lhs == rhs } : nil,
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            duplicateFilter: options.contains(.removeDuplicates) ? { @Sendable lhs, rhs in lhs == rhs } : nil,
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            debounce: options.debounceForObservation,
            debounceClock: clock,
            isolation: isolation,
            of: getter,
            onChange: { _ in
                await onChange()
            }
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
            duplicateFilter: options.contains(.removeDuplicates) ? { @Sendable lhs, rhs in lhs == rhs } : nil,
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            duplicateFilter: options.contains(.removeDuplicates) ? { @Sendable lhs, rhs in lhs == rhs } : nil,
            debounce: options.debounceForObservation,
            debounceClock: clock,
            isolation: isolation,
            of: getter,
            onChange: { _ in
                await onChange()
            }
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
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            debounce: options.debounceForObservation,
            debounceClock: clock,
            isolation: isolation,
            of: getter,
            task: { _ in
                await task()
            }
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
            duplicateFilter: options.contains(.removeDuplicates) ? { @Sendable lhs, rhs in lhs == rhs } : nil,
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            duplicateFilter: options.contains(.removeDuplicates) ? { @Sendable lhs, rhs in lhs == rhs } : nil,
            debounce: options.debounceForObservation,
            debounceClock: clock,
            isolation: isolation,
            of: getter,
            task: { _ in
                await task()
            }
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
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            duplicateFilter: options.contains(.removeDuplicates) ? { @Sendable lhs, rhs in lhs == rhs } : nil,
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            debounce: options.debounceForObservation,
            debounceClock: clock,
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
            duplicateFilter: options.contains(.removeDuplicates) ? { @Sendable lhs, rhs in lhs == rhs } : nil,
            debounce: options.debounceForObservation,
            debounceClock: clock,
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

private func hasSameObservationIsolation(
    _ lhs: (any Actor)?,
    _ rhs: (any Actor)?
) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case let (lhs?, rhs?):
        return ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
    default:
        return false
    }
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

private func makeNonSendableOnChangeAdapter<Value>(
    _ onChange: @escaping @isolated(any) @Sendable (sending Value) -> Void
) -> @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void {
    { boxedValue in
        await onChange(boxedValue.value)
    }
}

private func makeNonSendableTaskAdapter<Value>(
    _ task: @escaping @isolated(any) @Sendable (sending Value) async -> Void
) -> @isolated(any) @Sendable (sending _UncheckedSendableValueBox<Value>) async -> Void {
    { boxedValue in
        await task(boxedValue.value)
    }
}

enum ResolvedBackend: Sendable {
    case native
    case legacy
}

func makeObservationStream<Value: Sendable>(
    options: ObservationOptions = [],
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isolation: isolated (any Actor)? = #isolation,
    duplicateFilter: (@Sendable (Value, Value) -> Bool)? = nil,
    debounce: ObservationDebounce? = nil,
    debounceClock: any Clock<Duration> = ContinuousClock()
) -> AsyncStream<Value> {
    let stream = makeRawObservationStream(
        options: options,
        observe,
        isolation: observe.isolation ?? isolation
    )
    let streamWithDebounce: AsyncStream<Value>
    if let debounce {
        streamWithDebounce = makeDebouncedValueStream(
            stream,
            debounce: debounce,
            debounceClock: debounceClock
        )
    } else {
        streamWithDebounce = stream
    }

    return makeDuplicateFilteredStream(
        streamWithDebounce,
        isDuplicate: duplicateFilter
    )
}

func makeObservationStream<Value>(
    options: ObservationOptions = [],
    @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value,
    isolation: isolated (any Actor)? = #isolation,
    duplicateFilter: (@Sendable (Value, Value) -> Bool)? = nil,
    debounce: ObservationDebounce? = nil,
    debounceClock: any Clock<Duration> = ContinuousClock()
) -> AsyncStream<Value> {
    _ = options

    let boxedObserve: @isolated(any) @Sendable () -> _UncheckedSendableValueBox<Value> = {
        _UncheckedSendableValueBox(
            _ObservationBridgeLegacy.legacyEvaluateObservedValue(observe: observe)
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
        isDuplicate: boxedDuplicateFilter,
        isolation: observe.isolation ?? isolation
    )
    let stream = AsyncStream<Value> { continuation in
        let task = Task {
            for await boxedValue in boxedStream {
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

    let streamWithDebounce: AsyncStream<Value>
    if let debounce {
        streamWithDebounce = makeDebouncedValueStreamNonSendable(
            stream,
            debounce: debounce,
            debounceClock: debounceClock
        )
    } else {
        streamWithDebounce = stream
    }

    return streamWithDebounce
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

    private let stream: AsyncStream<Value>

    fileprivate init(stream: AsyncStream<Value>) {
        self.stream = stream
    }

    public init(
        options: ObservationOptions,
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates requires Value to conform to Equatable")
        }

        self.init(stream: makeObservationStream(
            options: options,
            observe,
            duplicateFilter: nil,
            debounce: options.debounceForObservation,
            debounceClock: clock
        ))
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: stream.makeAsyncIterator())
    }
}

extension ObservationBridge: Sendable where Value: Sendable {}

public extension ObservationBridge where Value: Sendable {
    init(
        options: ObservationOptions,
        clock: any Clock<Duration> = ContinuousClock(),
        @_inheritActorContext _ observe: @escaping @isolated(any) @Sendable () -> Value
    ) {
        if options.contains(.removeDuplicates) {
            preconditionFailure(".removeDuplicates requires Value to conform to Equatable")
        }

        self.init(stream: makeObservationStream(
            options: options,
            observe,
            duplicateFilter: nil,
            debounce: options.debounceForObservation,
            debounceClock: clock
        ))
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
        self.init(stream: makeObservationStream(
            options: options,
            observe,
            duplicateFilter: options.contains(.removeDuplicates) ? { @Sendable lhs, rhs in lhs == rhs } : nil,
            debounce: options.debounceForObservation,
            debounceClock: clock
        ))
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
        self.init(stream: makeObservationStream(
            options: options,
            observe,
            duplicateFilter: options.contains(.removeDuplicates) ? { @Sendable lhs, rhs in lhs == rhs } : nil,
            debounce: options.debounceForObservation,
            debounceClock: clock
        ))
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
