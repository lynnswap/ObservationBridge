import Synchronization

#if canImport(ObjectiveC)
import ObjectiveC
#endif

enum OwnerCancellationRegistry {
#if canImport(ObjectiveC)
    private static let storeLock = Mutex(())
    nonisolated(unsafe) private static var lifetimeStoreKey: UInt8 = 0
#endif

    static func register(
        _ box: ObservationHandleBox,
        owner: AnyObject
    ) {
#if canImport(ObjectiveC)
        let boxID = ObjectIdentifier(box)
        let store = loadOrCreateStore(owner: owner)
        store.insertCancellationHandler(id: boxID) { [weak box] in
            box?.cancel()
        }

        box.addCancellationHandler { [weak store] in
            store?.remove(id: boxID)
        }
#else
        _ = box
        _ = owner
#endif
    }

#if canImport(ObjectiveC)
    private static func loadOrCreateStore(owner: AnyObject) -> ObservationOwnerCancellationStore {
        storeLock.withLock { (_: inout ()) in
            if let existing = unsafe objc_getAssociatedObject(owner, &lifetimeStoreKey) as? ObservationOwnerCancellationStore {
                return existing
            }

            let store = ObservationOwnerCancellationStore()
            unsafe objc_setAssociatedObject(owner, &lifetimeStoreKey, store, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            guard let attached = unsafe objc_getAssociatedObject(owner, &lifetimeStoreKey) as? ObservationOwnerCancellationStore else {
                preconditionFailure("owner cancellation registration is unsupported for this owner type")
            }
            return attached
        }
    }
#endif
}
