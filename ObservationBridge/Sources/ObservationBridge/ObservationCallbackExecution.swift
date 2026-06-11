@discardableResult
func makeObservationTask<Success: Sendable>(
    @_inheritActorContext operation: @escaping @isolated(any) @Sendable () async -> Success
) -> Task<Success, Never> {
    if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
        return Task.immediate(operation: operation)
    }
    return Task(operation: operation)
}

struct _UncheckedSendableValueBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
