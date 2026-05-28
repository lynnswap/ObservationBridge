import Synchronization

private struct WeakOwnerReference: @unchecked Sendable {
    weak var owner: AnyObject?

    init(owner: AnyObject) {
        self.owner = owner
    }
}

enum WeakOwnerRegistry {
    private struct State {
        var nextToken: UInt64 = 1
        var owners: [UInt64: WeakOwnerReference] = [:]
    }

    private static let state = Mutex(State())

    static func createToken(owner: AnyObject) -> UInt64 {
        var token: UInt64 = 0
        state.withLock { (state: inout State) in
            token = state.nextToken
            state.nextToken &+= 1
            state.owners[token] = WeakOwnerReference(owner: owner)
        }
        return token
    }

    static func owner(token: UInt64) -> AnyObject? {
        let resolvedOwner = state.withLock { (state: inout State) -> AnyObject? in
            guard let reference = state.owners[token] else {
                return nil
            }

            guard let owner = reference.owner else {
                state.owners[token] = nil
                return nil
            }

            return owner
        }
        return resolvedOwner
    }

    static func removeToken(_ token: UInt64) {
        _ = state.withLock { (state: inout State) in
            state.owners.removeValue(forKey: token)
        }
    }
}
