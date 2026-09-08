import CoreVideo

/// Decoded frames keyed by presentation index, in a power-of-two ring:
/// slot = index & mask, so lookup is O(1) and a stale occupant is simply
/// overwritten. Not thread-safe on its own — `DeckVideoStream` guards it.
final class FrameRing {
    private struct Slot {
        var index = -1
        var buffer: CVPixelBuffer?
    }

    private var slots: [Slot]
    private let mask: Int
    let capacity: Int
    private(set) var count = 0

    init(capacity requested: Int) {
        var cap = 2
        while cap < max(2, requested) { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        slots = [Slot](repeating: Slot(), count: cap)
    }

    func buffer(at index: Int) -> CVPixelBuffer? {
        guard index >= 0 else { return nil }
        let slot = slots[index & mask]
        return slot.index == index ? slot.buffer : nil
    }

    func contains(_ index: Int) -> Bool {
        guard index >= 0 else { return false }
        return slots[index & mask].index == index
    }

    /// The nearest frame at or before `index`, scanning back `backscan` slots.
    func nearest(atOrBefore index: Int, backscan: Int) -> (index: Int, buffer: CVPixelBuffer)? {
        var i = index
        let stop = max(0, index - backscan)
        while i >= stop {
            let slot = slots[i & mask]
            if slot.index == i, let b = slot.buffer { return (i, b) }
            i -= 1
        }
        return nil
    }

    func insert(_ buffer: CVPixelBuffer, at index: Int) {
        guard index >= 0 else { return }
        let s = index & mask
        if slots[s].buffer == nil { count += 1 }
        slots[s] = Slot(index: index, buffer: buffer)
    }

    /// Release every frame for which `keep` is false.
    func retain(where keep: (Int) -> Bool) {
        for s in 0..<slots.count where slots[s].buffer != nil && !keep(slots[s].index) {
            slots[s] = Slot()
            count -= 1
        }
    }

    func removeAll() {
        for s in 0..<slots.count where slots[s].buffer != nil { slots[s] = Slot() }
        count = 0
    }
}
