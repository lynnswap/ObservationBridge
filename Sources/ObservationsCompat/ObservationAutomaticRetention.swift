import Synchronization

#if canImport(ObjectiveC)
import ObjectiveC
#endif

enum AutomaticRetentionRegistry {
#if canImport(ObjectiveC)
    private static let storeLock = Mutex(())
    nonisolated(unsafe) private static var lifetimeStoreKey: UInt8 = 0
#endif

    static func retain(
        _ box: ObservationHandleBox,
        owner: AnyObject
    ) {
#if canImport(ObjectiveC)
        let boxID = ObjectIdentifier(box)
        let store = loadOrCreateStore(owner: owner)
        store.insert(box, id: boxID)

        box.addCancellationHandler { [weak store] in
            store?.remove(id: boxID)
        }
#else
        _ = box
        _ = owner
#endif
    }

#if canImport(ObjectiveC)
    private static func loadOrCreateStore(owner: AnyObject) -> ObservationLifetimeStore {
        storeLock.withLock { (_: inout ()) in
            if let existing = unsafe objc_getAssociatedObject(owner, &lifetimeStoreKey) as? ObservationLifetimeStore {
                return existing
            }

            let store = ObservationLifetimeStore()
            unsafe objc_setAssociatedObject(owner, &lifetimeStoreKey, store, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            guard let attached = unsafe objc_getAssociatedObject(owner, &lifetimeStoreKey) as? ObservationLifetimeStore else {
                preconditionFailure("automatic retention is unsupported for this owner type")
            }
            return attached
        }
    }
#endif
}
