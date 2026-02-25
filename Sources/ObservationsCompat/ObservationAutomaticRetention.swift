import ObservationsCompatObjC
import Synchronization

enum AutomaticRetentionRegistry {
    private static let storeLock = Mutex(())

    static func retain(
        _ box: ObservationHandleBox,
        owner: AnyObject
    ) {
        let boxID = ObjectIdentifier(box)
        let store = loadOrCreateStore(owner: owner)
        store.insert(box, id: boxID)

        box.addCancellationHandler { [weak store] in
            store?.remove(id: boxID)
        }
    }

    private static func loadOrCreateStore(owner: AnyObject) -> ObservationLifetimeStore {
        storeLock.withLock { _ in
            if let existing = ObservationsCompatGetLifetimeStore(owner) as? ObservationLifetimeStore {
                return existing
            }

            let store = ObservationLifetimeStore()
            ObservationsCompatSetLifetimeStore(owner, store)
            guard let attached = ObservationsCompatGetLifetimeStore(owner) as? ObservationLifetimeStore else {
                preconditionFailure("automatic retention is unsupported for this owner type")
            }
            return attached
        }
    }
}
