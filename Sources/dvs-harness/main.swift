// dvs-harness — spike/measurement CLI for DeckVideoStream.
//
//   dvs-harness probe <file>
//   dvs-harness throughput <file> [--format bgra8|nv12VideoRange] [--max-frames N] [--streams N]
//   dvs-harness coldseek <file> [--trials N] [--format F] [--mode restart|reset]
//   dvs-harness reorder <file> [--gops N]
//   dvs-harness pin <file> [--frames N] [--format F]
//   dvs-harness alpha <file>

import AVFoundation
import DeckVideoStream
import Foundation

// MARK: - Helpers

struct Args {
    let command: String
    let file: URL
    let options: [String: String]

    init?(_ argv: [String]) {
        guard argv.count >= 3 else { return nil }
        command = argv[1]
        file = URL(fileURLWithPath: argv[2])
        var opts = [String: String]()
        var i = 3
        while i < argv.count {
            let key = argv[i]
            guard key.hasPrefix("--") else { i += 1; continue }
            if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                opts[String(key.dropFirst(2))] = argv[i + 1]; i += 2
            } else {
                opts[String(key.dropFirst(2))] = "true"; i += 1
            }
        }
        options = opts
    }

    func int(_ key: String, _ def: Int) -> Int { options[key].flatMap(Int.init) ?? def }
    func string(_ key: String, _ def: String) -> String { options[key] ?? def }
    func format(_ def: PixelFormat = .bgra8) -> PixelFormat {
        options["format"].flatMap(PixelFormat.init(rawValue:)) ?? def
    }
}

func physFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : -1
}

func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
func ms(_ s: Double) -> String { String(format: "%.2f ms", s * 1000) }

struct Stats {
    let min: Double, median: Double, p90: Double, max: Double, mean: Double
    init(_ values: [Double]) {
        let s = values.sorted()
        min = s.first ?? 0; max = s.last ?? 0
        median = s.isEmpty ? 0 : s[s.count / 2]
        p90 = s.isEmpty ? 0 : s[Swift.min(s.count - 1, Int(Double(s.count) * 0.9))]
        mean = s.isEmpty ? 0 : s.reduce(0, +) / Double(s.count)
    }
    var line: String { "min \(ms(min))  med \(ms(median))  p90 \(ms(p90))  max \(ms(max))" }
}

func printInfo(_ info: SourceInfo) {
    print("file:        \(info.url.lastPathComponent)")
    print("codec:       \(info.codec)  \(info.width)x\(info.height)  alpha=\(info.hasAlpha)  bframes=\(info.hasBFrames)")
    print(String(format: "frames:      %d  %.3f fps nominal  %.2f s", info.frameCount, info.nominalFrameRate, info.durationSeconds))
    let g = info.gop
    let fps = info.nominalFrameRate > 0 ? info.nominalFrameRate : 1
    print(String(format: "keyframes:   %d  GOP min/med/max = %d/%d/%d frames (%.2f/%.2f/%.2f s), worst starts at frame %d",
                 info.keyframeCount, g.minFrames, g.medianFrames, g.maxFrames,
                 Double(g.minFrames) / fps, Double(g.medianFrames) / fps, Double(g.maxFrames) / fps, g.maxStartIndex))
    print("index:       built with \(info.tableBuilder.rawValue) (cursors=\(info.canProvideSampleCursors)) in \(ms(info.openSeconds))")
    print("bytes/frame: bgra8 \(mb(info.bytesPerFrame(.bgra8)))  nv12 \(mb(info.bytesPerFrame(.nv12VideoRange)))")
}

// MARK: - Commands

func probe(_ src: VideoSource) {
    printInfo(src.info)
    let t = src.table
    let n = min(8, t.count)
    let first = (0..<n).map { String(format: "%.3f", t.seconds(at: $0)) }.joined(separator: " ")
    print("first pts:   \(first)")
    let syncs = t.syncIndices.prefix(10).map { String($0) }.joined(separator: " ")
    print("sync idx:    \(syncs) ...")
}

/// Sequential decode from 0; returns (frames, seconds).
func decodeRun(_ src: VideoSource, format: PixelFormat, maxFrames: Int, holding: inout [CVPixelBuffer]?) throws -> (Int, Double) {
    let reader = ReaderSource(source: src, pixelFormat: format)
    try reader.start(atSeconds: 0)
    let t0 = HostClock.seconds()
    var n = 0
    while n < maxFrames, let f = reader.next() {
        n += 1
        holding?.append(f.pixelBuffer)
    }
    let dt = HostClock.seconds() - t0
    if let err = reader.error { print("reader error: \(err)") }
    reader.cancel()
    return (n, dt)
}

func throughput(_ src: VideoSource, args: Args) throws {
    printInfo(src.info)
    let maxFrames = args.int("max-frames", src.info.frameCount)
    let formats: [PixelFormat] = args.options["format"] != nil ? [args.format()] : PixelFormat.allCases
    for fmt in formats {
        var none: [CVPixelBuffer]? = nil
        let (n, dt) = try decodeRun(src, format: fmt, maxFrames: maxFrames, holding: &none)
        print(String(format: "%-16@ 1 stream : %5d frames in %6.2f s = %7.1f fps (%.1fx realtime)",
                     fmt.rawValue as NSString, n, dt, Double(n) / dt, Double(n) / dt / max(1, src.info.nominalFrameRate)))
    }
    let streams = args.int("streams", 2)
    if streams > 1 {
        for fmt in formats {
            let group = DispatchGroup()
            let lock = NSLock()
            var total = 0
            let t0 = HostClock.seconds()
            for _ in 0..<streams {
                group.enter()
                Thread.detachNewThread {
                    var none: [CVPixelBuffer]? = nil
                    if let (n, _) = try? decodeRun(src, format: fmt, maxFrames: maxFrames, holding: &none) {
                        lock.lock(); total += n; lock.unlock()
                    }
                    group.leave()
                }
            }
            group.wait()
            let dt = HostClock.seconds() - t0
            print(String(format: "%-16@ %d streams: %5d frames in %6.2f s = %7.1f fps aggregate (%.1f per stream)",
                         fmt.rawValue as NSString, streams, total, dt, Double(total) / dt, Double(total) / dt / Double(streams)))
        }
    }
}

func coldseek(_ src: VideoSource, args: Args) throws {
    printInfo(src.info)
    let trials = args.int("trials", 10)
    let fmt = args.format()
    let mode = args.string("mode", "restart")
    let t = src.table
    let g = src.info.gop
    let gopStart = g.maxStartIndex
    let gopEnd = t.nextKeyframeIndex(after: gopStart)
    let gopLen = gopEnd - gopStart
    print("worst GOP:   frames \(gopStart)..<\(gopEnd) (\(gopLen) frames), mode=\(mode), format=\(fmt.rawValue), trials=\(trials)")
    print("target      offset  create+start        first-frame (total)                     first pts vs target   frames before target")
    for fraction in [0.0, 0.25, 0.5, 1.0] {
        let target = min(gopEnd - 1, gopStart + Int(Double(gopLen - 1) * fraction))
        let targetSeconds = t.seconds(at: target)
        var creates = [Double](), firsts = [Double](), skipped = [Int](), firstPTSDelta = [Double]()
        for _ in 0..<trials {
            let reader = ReaderSource(source: src, pixelFormat: fmt, randomAccess: mode == "reset")
            let t0 = HostClock.seconds()
            var createDT: Double
            if mode == "reset" {
                // Prime: read a 1-frame range at the file start to exhaustion, then retarget.
                createDT = try reader.start(atIndex: 0, endIndex: 1)
                while reader.next() != nil {}
                let t1 = HostClock.seconds()
                try reader.reset(toIndex: target)
                createDT = HostClock.seconds() - t1
            } else {
                createDT = try reader.start(atIndex: target)
            }
            let tStart = mode == "reset" ? HostClock.seconds() - createDT : t0
            var before = 0
            var firstPTS: Double? = nil
            var got: DecodedFrame? = nil
            while let f = reader.next() {
                if firstPTS == nil { firstPTS = f.seconds }
                if f.seconds >= targetSeconds - 1e-6 { got = f; break }
                before += 1
            }
            let dt = HostClock.seconds() - tStart
            reader.cancel()
            guard got != nil else { print("  trial failed: no frame at target (status \(String(describing: reader.status)) err \(String(describing: reader.error)))"); continue }
            creates.append(createDT); firsts.append(dt); skipped.append(before)
            firstPTSDelta.append((firstPTS ?? targetSeconds) - targetSeconds)
        }
        let c = Stats(creates), f = Stats(firsts)
        let sk = skipped.isEmpty ? 0 : skipped.sorted()[skipped.count / 2]
        let fd = firstPTSDelta.isEmpty ? 0 : firstPTSDelta.sorted()[firstPTSDelta.count / 2]
        print(String(format: "%3.0f%%  +%4d frames  med %@   %@   %+8.3f s   %d",
                     fraction * 100, target - gopStart, ms(c.median), f.line, fd, sk))
    }
}

func reorder(_ src: VideoSource, args: Args) throws {
    printInfo(src.info)
    let gops = args.int("gops", 5)
    let t = src.table
    let endIndex = t.syncIndices.count > gops ? Int(t.syncIndices[gops]) : t.count
    let endSeconds = endIndex < t.count ? t.seconds(at: endIndex) : t.durationSeconds + 1
    let reader = ReaderSource(source: src, pixelFormat: .bgra8)
    try reader.start(atSeconds: 0, endSeconds: endSeconds)
    var decoded = [Double]()
    while let f = reader.next() { decoded.append(f.seconds) }
    reader.cancel()
    let expected = (0..<endIndex).map { t.seconds(at: $0) }
    var monotonic = true
    for i in 1..<max(1, decoded.count) where decoded[i] <= decoded[i - 1] { monotonic = false; break }
    var mismatches = 0
    for i in 0..<min(decoded.count, expected.count) where abs(decoded[i] - expected[i]) > 1e-4 { mismatches += 1 }
    print("first \(gops) GOPs: table \(expected.count) frames, decoded \(decoded.count) frames, monotonic=\(monotonic), pts mismatches=\(mismatches)")
    if decoded.count != expected.count || mismatches > 0 {
        print("  table  head: \(expected.prefix(6).map { String(format: "%.4f", $0) })")
        print("  decode head: \(decoded.prefix(6).map { String(format: "%.4f", $0) })")
        print("  table  tail: \(expected.suffix(3).map { String(format: "%.4f", $0) })")
        print("  decode tail: \(decoded.suffix(3).map { String(format: "%.4f", $0) })")
    }
    let d = t.decodeOrdinal.prefix(12).map { String($0) }.joined(separator: " ")
    print("decode ordinals of first 12 presentation frames: \(d)")
}

func pin(_ src: VideoSource, args: Args) throws {
    printInfo(src.info)
    let frames = args.int("frames", 200)
    let fmt = args.format()
    let expected = frames * src.info.bytesPerFrame(fmt)
    let base = physFootprint()
    var held: [CVPixelBuffer]? = []
    let (n, dt) = try decodeRun(src, format: fmt, maxFrames: frames, holding: &held)
    let during = physFootprint()
    var actualBytes = 0
    var rowPadded = 0
    for pb in held ?? [] {
        actualBytes += CVPixelBufferGetDataSize(pb)
        rowPadded += CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb)
    }
    print(String(format: "held %d %@ frames (decoded in %.2f s)", n, fmt.rawValue as NSString, dt))
    print("expected     \(mb(expected))  (nominal w*h*bpp)")
    print("CV data size \(mb(actualBytes))  (CVPixelBufferGetDataSize sum; row-padded plane0 \(mb(rowPadded)))")
    print("footprint    base \(mb(base)) → held \(mb(during))  Δ \(mb(during - base))")
    let hold = args.int("hold", 0)
    if hold > 0 {
        print("holding \(hold) s for external inspection (pid \(getpid()))"); fflush(stdout)
        Thread.sleep(forTimeInterval: Double(hold))
    }
    held = nil
    // Give the pool a moment to return surfaces.
    Thread.sleep(forTimeInterval: 0.5)
    let after = physFootprint()
    print("             released → \(mb(after))  Δ vs base \(mb(after - base))")
    if hold > 0 {
        print("holding \(hold) s after release (pid \(getpid()))"); fflush(stdout)
        Thread.sleep(forTimeInterval: Double(hold))
    }
}

func alpha(_ src: VideoSource, args: Args) throws {
    printInfo(src.info)
    guard src.info.hasAlpha else { print("format description reports NO alpha channel; decoding first frame anyway"); return alphaSample(src) }
    alphaSample(src)
}

func alphaSample(_ src: VideoSource) {
    let reader = ReaderSource(source: src, pixelFormat: .bgra8)
    do { try reader.start(atSeconds: 0) } catch { print("start failed: \(error)"); return }
    guard let f = reader.next() else { print("no frame (status \(String(describing: reader.status)), err \(String(describing: reader.error)))"); return }
    let pb = f.pixelBuffer
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { print("no base address"); return }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rowBytes = CVPixelBufferGetBytesPerRow(pb)
    var minA: UInt8 = 255, maxA: UInt8 = 0
    var histogram = [Int](repeating: 0, count: 4)
    let p = base.assumingMemoryBound(to: UInt8.self)
    for y in stride(from: 0, to: h, by: 4) {
        for x in stride(from: 0, to: w, by: 4) {
            let a = p[y * rowBytes + x * 4 + 3]
            minA = min(minA, a); maxA = max(maxA, a)
            histogram[Int(a) / 64] += 1
        }
    }
    print("first frame: \(w)x\(h) format \(fourCCString(CVPixelBufferGetPixelFormatType(pb)))  alpha min \(minA) max \(maxA)  quartile histogram \(histogram)")
    print(maxA == minA ? "alpha is CONSTANT — no usable alpha" : "alpha varies — usable")
    reader.cancel()
}

func fourCCString(_ code: OSType) -> String {
    let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
    return String(bytes: bytes, encoding: .macOSRoman) ?? String(code)
}

// MARK: - Main

guard let args = Args(CommandLine.arguments) else {
    print("usage: dvs-harness <probe|throughput|coldseek|reorder|pin|alpha> <file> [--options]")
    exit(2)
}

do {
    let src = try await VideoSource.open(args.file)
    switch args.command {
    case "probe": probe(src)
    case "throughput": try throughput(src, args: args)
    case "coldseek": try coldseek(src, args: args)
    case "reorder": try reorder(src, args: args)
    case "pin": try pin(src, args: args)
    case "alpha": try alpha(src, args: args)
    default: print("unknown command \(args.command)"); exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
