import Synchronization

final class ObservationLifetimeStore: Sendable {
    private struct State {
        var boxes: [ObjectIdentifier: ObservationHandleBox] = [:]
    }

    private let state = Mutex(State())

    func insert(_ box: ObservationHandleBox, id: ObjectIdentifier) {
        state.withLock { state in
            state.boxes[id] = box
        }
    }

    func remove(id: ObjectIdentifier) {
        state.withLock { state in
            state.boxes[id] = nil
        }
    }

    deinit {
        let boxesToCancel = state.withLock { state in
            let boxes = Array(state.boxes.values)
            state.boxes.removeAll(keepingCapacity: false)
            return boxes
        }

        for box in boxesToCancel {
            box.cancel()
        }
    }
}
