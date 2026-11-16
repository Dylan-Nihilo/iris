import Foundation
import CoreVideo

/// Notes where the picture changes while it is being recorded, about ten times a second.
/// The render uses it to tell a quiet stretch from a busy one, and to find what to look at
/// in a recording nobody declared anything about.
final class ChangeDetector {
    private let handle: FileHandle?
    private var previous: [UInt8] = []
    private var current: [UInt8] = []
    private var lastTime = -Double.infinity
    private let interval = 0.1
    /// Brightness difference, out of 255, that counts as a change. Frames arrive straight
    /// from the window server, so anything above rounding noise is real.
    private let threshold = 10

    init(store: SessionStore) {
        FileManager.default.createFile(atPath: store.changesURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: store.changesURL)
    }

    func close() {
        try? handle?.close()
    }

    func observe(_ buffer: CVPixelBuffer, host: Double) {
        guard host - lastTime >= interval else { return }
        lastTime = host
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let step = max(1, width / 480)
        let cols = width / step, rows = height / step
        guard cols > 0, rows > 0 else { return }

        if current.count != cols * rows { current = [UInt8](repeating: 0, count: cols * rows) }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<rows {
            let line = pixels + (row * step + step / 2) * stride
            for col in 0..<cols {
                let p = line + (col * step + step / 2) * 4
                // BGRA to a rough brightness.
                current[row * cols + col] = UInt8((Int(p[0]) + Int(p[1]) * 5 + Int(p[2]) * 2) >> 3)
            }
        }
        defer { swap(&previous, &current) }
        guard previous.count == current.count else { return }

        var count = 0
        var minCol = cols, maxCol = -1, minRow = rows, maxRow = -1
        for row in 0..<rows {
            for col in 0..<cols where abs(Int(current[row * cols + col]) - Int(previous[row * cols + col])) > threshold {
                count += 1
                if col < minCol { minCol = col }
                if col > maxCol { maxCol = col }
                if row < minRow { minRow = row }
                if row > maxRow { maxRow = row }
            }
        }
        guard count > 0 else { return }
        let spanCols = maxCol - minCol + 1, spanRows = maxRow - minRow + 1
        // A blinking text caret: a sliver a couple of samples wide and a line of text tall.
        let sliver = spanCols <= 2 && spanRows * step <= 80
        let event = ChangeEvent(u: host, n: Double(count) / Double(cols * rows),
                                x: Double(minCol) / Double(cols), y: Double(minRow) / Double(rows),
                                w: Double(spanCols) / Double(cols), h: Double(spanRows) / Double(rows),
                                s: sliver ? 1 : nil)
        guard let handle, var data = try? SessionStore.lineEncoder.encode(event) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }
}
