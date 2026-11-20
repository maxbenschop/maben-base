import AppKit

/// --demo --bench: scrolls the open grid down and across the way a swipe does, and prints how much work the
/// app had to do for each frame. A 60 Hz screen leaves 16.7 ms per frame; anything over that is a dropped frame.
@MainActor
enum GridBench {
    static func run(in window: NSWindow?) {
        guard let window, let table = find(GridTableView.self, in: window.contentView), let scroll = table.enclosingScrollView else {
            print("bench: no grid in the window")
            exit(1)
        }
        let clip = scroll.contentView
        let maxY = max(0, table.frame.height - clip.bounds.height), maxX = max(0, table.frame.width - clip.bounds.width)
        /// The main thread's own time for one scroll step, in ms. Time spent waiting for the screen isn't the
        /// app's work and isn't counted.
        func frame(_ origin: NSPoint) -> Double {
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000
        }
        func report(_ name: String, _ times: [Double]) {
            guard !times.isEmpty else { return print("bench \(name): nothing to scroll") }
            let sorted = times.sorted()
            let dropped = times.filter { $0 > 1000.0 / 60 }.count
            print(String(format: "bench %@: %d frames, median %.1f ms, p95 %.1f ms, worst %.1f ms, over 16.7 ms: %d (%.0f%%)",
                         name, times.count, sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 95 / 100)],
                         sorted[sorted.count - 1], dropped, Double(dropped) / Double(times.count) * 100))
        }
        print("bench: \(table.numberOfColumns) columns, \(table.numberOfRows) rows, \(Int(clip.bounds.width))×\(Int(clip.bounds.height)) pt")
        _ = frame(.zero)
        // A fast swipe moves about four rows a frame, a slow one a third of a row; dragging the scroller jumps.
        for (name, step) in [("down fast", 96.0), ("down slow", 8.0), ("jumping", max(96, (maxY / 120).rounded()))] {
            var times: [Double] = []
            for y in stride(from: step, through: min(maxY, step * 240), by: step) { times.append(frame(NSPoint(x: 0, y: y))) }
            report(name, times)
            _ = frame(.zero)
        }
        var times: [Double] = []
        for x in stride(from: 60.0, through: min(maxX, 60 * 240), by: 60) { times.append(frame(NSPoint(x: x, y: 0))) }
        report("across", times)
        exit(0)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let hit = view as? T { return hit }
        for sub in view.subviews { if let hit = find(type, in: sub) { return hit } }
        return nil
    }
}
