/// Pure helpers for turning oracle samples into decode work.
enum DecodePlanner {
    /// Merge sampled presentation indices into contiguous runs. Indices
    /// separated by at most `gapTolerance` missing frames join one run —
    /// a tempo ratio above 1 skips frames between samples, and those still
    /// have to be decoded (the reader is sequential anyway). A loop wrap
    /// inside the horizon shows up as a second, earlier run.
    static func runs(from indices: [Int], gapTolerance: Int) -> [ClosedRange<Int>] {
        let sorted = Set(indices.filter { $0 >= 0 }).sorted()
        guard var lo = sorted.first else { return [] }
        var hi = lo
        var runs = [ClosedRange<Int>]()
        for i in sorted.dropFirst() {
            if i - hi > gapTolerance + 1 {
                runs.append(lo...hi)
                lo = i
            }
            hi = i
        }
        runs.append(lo...hi)
        return runs
    }
}
