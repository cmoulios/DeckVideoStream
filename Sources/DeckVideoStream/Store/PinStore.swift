import CoreVideo

/// Contiguous ranges of frames held regardless of the live window: a loop
/// (so wraps never decode), or the few frames around a cue point (so a
/// jump there shows the right frame on the first tick). Not thread-safe
/// on its own — `DeckVideoStream` guards it with the same lock as the ring.
final class PinStore {
    final class Range {
        let key: PinKey
        let first: Int
        var buffers: [CVPixelBuffer?]
        /// Frames present (buffers.count is the reserved size).
        private(set) var count = 0
        let bytesPerFrame: Int

        init(key: PinKey, first: Int, length: Int, bytesPerFrame: Int) {
            self.key = key
            self.first = first
            self.buffers = [CVPixelBuffer?](repeating: nil, count: length)
            self.bytesPerFrame = bytesPerFrame
        }

        var last: Int { first + buffers.count - 1 }
        var isComplete: Bool { count == buffers.count }
        /// Bytes reserved in the budget (the full range, present or not).
        var reservedBytes: Int { buffers.count * bytesPerFrame }

        func contains(_ index: Int) -> Bool { index >= first && index <= last }

        func buffer(at index: Int) -> CVPixelBuffer? {
            guard contains(index) else { return nil }
            return buffers[index - first]
        }

        func insert(_ buffer: CVPixelBuffer, at index: Int) {
            guard contains(index) else { return }
            if buffers[index - first] == nil { count += 1 }
            buffers[index - first] = buffer
        }

        /// First missing index at or after `from`, if any.
        func firstMissing(from: Int = Int.min) -> Int? {
            let start = max(first, from)
            guard start <= last else { return nil }
            for i in start...last where buffers[i - first] == nil { return i }
            return nil
        }
    }

    enum PinKey: Hashable {
        case loop(LoopHint)
        case loopHead(LoopHint)
        case cue(Double)
    }

    private(set) var ranges: [Range] = []

    func range(for key: PinKey) -> Range? { ranges.first { $0.key == key } }

    func add(_ range: Range) { ranges.append(range) }

    @discardableResult
    func remove(where predicate: (Range) -> Bool) -> [Range] {
        let removed = ranges.filter(predicate)
        ranges.removeAll(where: predicate)
        return removed
    }

    func buffer(at index: Int) -> CVPixelBuffer? {
        for r in ranges { if let b = r.buffer(at: index) { return b } }
        return nil
    }

    /// Nearest pinned frame at or before `index` within `backscan`.
    func nearest(atOrBefore index: Int, backscan: Int) -> (index: Int, buffer: CVPixelBuffer)? {
        var i = index
        let stop = max(0, index - backscan)
        while i >= stop {
            if let b = buffer(at: i) { return (i, b) }
            i -= 1
        }
        return nil
    }

    var residentBytes: Int { ranges.reduce(0) { $0 + $1.count * $1.bytesPerFrame } }
    var reservedBytes: Int { ranges.reduce(0) { $0 + $1.reservedBytes } }
}
