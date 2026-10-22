import Foundation

/// The recorded fixture content is a constant, unique palette color per window.
/// Comparing owners therefore compares the actual start/final content at each
/// sampled pixel, independently of Accessibility and the policy's layout.
struct InstantPixelRecording: Decodable {
    struct Frame: Decodable {
        let time: Double
        let owners: Data
        func pixels(count: Int) throws -> [UInt8] {
            let bytes = [UInt8](owners)
            guard bytes.count.isMultiple(of: 5) else { throw HarnessError("malformed palette recording") }
            var result: [UInt8] = []; result.reserveCapacity(count)
            for offset in stride(from: 0, to: bytes.count, by: 5) {
                let length = bytes[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) }
                guard length > 0, result.count + length <= count else { throw HarnessError("invalid palette run length") }
                result.append(contentsOf: repeatElement(bytes[offset + 4], count: length))
            }
            guard result.count == count else { throw HarnessError("incomplete palette frame") }
            return result
        }
    }
    struct Analysis: Codable {
        let intermediateFrames: Int
        let gapFrames: Int
        let comparedFrames: Int
        let changedPixels: Int
        let maximumCallbackGapMilliseconds: Double
    }
    let width: Int
    let height: Int
    let frames: [Frame]
    let failure: String?
    let requestedHz: Int

    func analyze(postedAt: Double, pointsWide: Double, arrival: UInt8? = nil, departing: UInt8? = nil,
                 initialArrival: [Double]? = nil, finalArrival: [Double]? = nil) throws -> Analysis {
        guard width > 0, height > 0, width * height <= 4_000_000, failure == nil, requestedHz == 120,
              let before = frames.last(where: { $0.time <= postedAt }), let last = frames.last, last.time > postedAt else {
            throw HarnessError("recording must bracket the command with successful 120 Hz capture")
        }
        // Open and close are native operations before policy can respond. The
        // start view includes the app's new window, or excludes its destroyed
        // window, just like the deterministic trace's start boundary.
        var first = before
        if let arrival {
            guard let born = try frames.first(where: { frame in
                guard frame.time >= postedAt else { return false }
                return try frame.pixels(count: width * height).contains(arrival) }) else {
                throw HarnessError("the recording never saw the new fixture")
            }
            first = born
        }
        if let departing {
            guard let destroyed = try frames.first(where: { frame in
                guard frame.time >= postedAt else { return false }
                return try !frame.pixels(count: width * height).contains(departing) }) else {
                throw HarnessError("the recording never saw the fixture close")
            }
            first = destroyed
        }
        let start = try first.pixels(count: width * height), end = try last.pixels(count: width * height)
        // Exclude 12 pt around start/final content edges, title bars and corners.
        let border = max(1, Int(ceil(12 * Double(width) / pointsWide)))
        var compare: [Int] = [], changed = 0
        for y in border..<(height - border) {
            for x in border..<(width - border) {
                let index = y * width + x
                let stable = [-border, border].allSatisfy { offset in
                    start[index] == start[index + offset] && start[index] == start[index + offset * width]
                        && end[index] == end[index + offset] && end[index] == end[index + offset * width]
                }
                if stable { compare.append(index); if start[index] != end[index] { changed += 1 } }
            }
        }
        let initialBox: [Int]?, finalBox: [Int]?
        if let arrival {
            guard let initialArrival, let finalArrival, initialArrival.count == 4, finalArrival.count == 4,
                  let box = paletteBounds(arrival, in: end) else { throw HarnessError("opening needs native initial/final geometry and final pixels") }
            let scale = Double(width) / pointsWide
            initialBox = [box[0] + Int(((initialArrival[0] - finalArrival[0]) * scale).rounded()),
                          box[1] + Int(((initialArrival[1] - finalArrival[1]) * scale).rounded()),
                          box[2] + Int(((initialArrival[0] + initialArrival[2] - finalArrival[0] - finalArrival[2]) * scale).rounded()),
                          box[3] + Int(((initialArrival[1] + initialArrival[3] - finalArrival[1] - finalArrival[3]) * scale).rounded())]
            finalBox = box
        } else { initialBox = nil; finalBox = nil }
        var intermediate = 0, gaps = 0, count = 0, previous = first.time, largestGap = 0.0, arrivalHasLanded = false
        for frame in frames where frame.time >= first.time && frame.time > postedAt {
            let current = try frame.pixels(count: width * height)
            var bad = false, gap = false
            for index in compare {
                let value = current[index]
                if value != start[index] && value != end[index] { bad = true }
                if start[index] != 0 && end[index] != 0 && value == 0 { gap = true }
            }
            if let arrival, let initialBox, let finalBox {
                let box = paletteBounds(arrival, in: current)
                func matches(_ expected: [Int]) -> Bool { box.map { zip($0, expected).allSatisfy { abs($0 - $1) <= 1 } } == true }
                let landed = matches(finalBox)
                if !landed && (arrivalHasLanded || !matches(initialBox)) { bad = true }
                arrivalHasLanded = arrivalHasLanded || landed
            }
            if bad { intermediate += 1 }; if gap { gaps += 1 }; count += 1
            largestGap = max(largestGap, frame.time - previous); previous = frame.time
        }
        return Analysis(intermediateFrames: intermediate, gapFrames: gaps, comparedFrames: count, changedPixels: changed,
                        maximumCallbackGapMilliseconds: largestGap * 1000)
    }

    private func paletteBounds(_ palette: UInt8, in pixels: [UInt8]) -> [Int]? {
        var x0 = width, y0 = height, x1 = -1, y1 = -1
        for index in pixels.indices where pixels[index] == palette {
            let x = index % width, y = index / width
            x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
        }
        return x1 >= 0 ? [x0, y0, x1, y1] : nil
    }

    func owner(_ palette: UInt8, at frame: [Double], points: [Double], last: Bool, postedAt: Double) throws -> Bool {
        guard frame.count == 4, points.count == 2, let sample = last ? frames.last : frames.last(where: { $0.time <= postedAt }) else { return false }
        let x = Int((frame[0] + frame[2] / 2) * Double(width) / points[0])
        let y = Int((frame[1] + frame[3] / 2) * Double(height) / points[1])
        guard (0..<width).contains(x), (0..<height).contains(y) else { return false }
        return try sample.pixels(count: width * height)[y * width + x] == palette
    }
}
