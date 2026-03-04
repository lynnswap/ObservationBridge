import Synchronization

private final class WeakOwnerBox {
    weak var owner: AnyObject?

    init(owner: AnyObject) {
        self.owner = owner
    }
}

enum WeakOwnerRegistry {
    private struct State {
        var nextToken: UInt64 = 1
        var owners: [UInt64: WeakOwnerBox] = [:]
    }

    private static let state = Mutex(State())

    static func createToken(owner: AnyObject) -> UInt64 {
        var token: UInt64 = 0
        state.withLock { (state: inout State) in
            token = state.nextToken
            state.nextToken &+= 1
            state.owners[token] = WeakOwnerBox(owner: owner)
        }
        return token
    }

    static func owner(token: UInt64) -> AnyObject? {
        var resolvedOwner: AnyObject?
        state.withLock { (state: inout State) in
            guard let box = state.owners[token] else {
                return
            }

            guard let owner = box.owner else {
                state.owners[token] = nil
                return
            }

            resolvedOwner = owner
        }
        return resolvedOwner
    }

    static func removeToken(_ token: UInt64) {
        state.withLock { (state: inout State) in
            state.owners[token] = nil
        }
    }
}
