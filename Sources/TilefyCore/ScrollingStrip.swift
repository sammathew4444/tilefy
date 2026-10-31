import CoreGraphics

/// The scrolling layout (niri / PaperWM / Omarchy's scrolling mode): an endless row of columns.
/// New windows join the row without resizing anything, and the viewport slides to keep the
/// focused column in view.
struct ScrollingStrip {
    struct Column: Codable, Equatable {
        var windows: [WindowID]
        /// Fraction of the viewport width, so it survives moving between displays.
        var width: CGFloat
    }

    static let widthPresets: [CGFloat] = [1.0 / 2.0, 2.0 / 3.0, 1.0]
    static let minimumWidth: CGFloat = 0.15

    var columns: [Column] = []
    var offset: CGFloat = 0
    var defaultWidth: CGFloat = 0.5

    private func columnIndex(of id: WindowID) -> Int? {
        columns.firstIndex { $0.windows.contains(id) }
    }

    /// Pixel width such that N columns of width 1/N exactly fill the viewport.
    private func pixelWidth(_ fraction: CGFloat, viewport: CGFloat, gap: CGFloat) -> CGFloat {
        ((viewport + gap) * fraction - gap).rounded()
    }

    mutating func insert(_ id: WindowID, after target: WindowID?) {
        let column = Column(windows: [id], width: defaultWidth)
        if let target, let index = columnIndex(of: target) {
            columns.insert(column, at: index + 1)
        } else {
            columns.append(column)
        }
    }

    mutating func remove(_ id: WindowID) {
        guard let index = columnIndex(of: id) else { return }
        columns[index].windows.removeAll { $0 == id }
        if columns[index].windows.isEmpty { columns.remove(at: index) }
    }

    /// Puts another window in the same place in the row.
    mutating func replace(_ old: WindowID, with new: WindowID) {
        guard let column = columnIndex(of: old), let row = columns[column].windows.firstIndex(of: old) else { return }
        columns[column].windows[row] = new
    }

    mutating func swap(_ a: WindowID, _ b: WindowID) {
        guard let columnA = columnIndex(of: a), let columnB = columnIndex(of: b) else { return }
        // Two whole columns trade places, and their widths travel with them.
        if columnA != columnB, columns[columnA].windows.count == 1, columns[columnB].windows.count == 1 {
            columns.swapAt(columnA, columnB)
            return
        }
        let rowA = columns[columnA].windows.firstIndex(of: a)!
        let rowB = columns[columnB].windows.firstIndex(of: b)!
        columns[columnA].windows[rowA] = b
        columns[columnB].windows[rowB] = a
    }

    mutating func cycleWidth(of id: WindowID) {
        guard let index = columnIndex(of: id) else { return }
        let current = columns[index].width
        let next = Self.widthPresets.first { $0 > current + 0.01 } ?? Self.widthPresets[0]
        columns[index].width = next
    }

    mutating func setFullWidth(of id: WindowID) {
        guard let index = columnIndex(of: id) else { return }
        columns[index].width = 1
    }

    mutating func grow(_ id: WindowID, by delta: CGFloat, viewport: CGFloat, gap: CGFloat) {
        guard let index = columnIndex(of: id), viewport > 0 else { return }
        let width = columns[index].width + delta / (viewport + gap)
        columns[index].width = min(1, max(Self.minimumWidth, width))
    }

    mutating func balance() {
        for index in columns.indices { columns[index].width = defaultWidth }
    }

    /// Merges the window into the column to its left, to form a stack.
    mutating func stackIntoPrevious(_ id: WindowID) {
        guard let index = columnIndex(of: id), index > 0 else { return }
        remove(id)
        columns[index - 1].windows.append(id)
    }

    /// Pulls the window out of its stack into its own column just to the right.
    mutating func unstack(_ id: WindowID) {
        guard let index = columnIndex(of: id), columns[index].windows.count > 1 else { return }
        columns[index].windows.removeAll { $0 == id }
        columns.insert(Column(windows: [id], width: columns[index].width), at: index + 1)
    }

    mutating func center(_ id: WindowID, viewport: CGFloat, gap: CGFloat, suspended: Set<WindowID>) {
        guard let span = span(of: id, viewport: viewport, gap: gap, suspended: suspended) else { return }
        offset = span.lowerBound - (viewport - (span.upperBound - span.lowerBound)) / 2
    }

    /// Where the column holding `id` sits along the (virtual, unscrolled) row.
    private func span(
        of id: WindowID,
        viewport: CGFloat,
        gap: CGFloat,
        suspended: Set<WindowID>
    ) -> ClosedRange<CGFloat>? {
        var x: CGFloat = 0
        for column in columns where column.windows.contains(where: { !suspended.contains($0) }) {
            let width = pixelWidth(column.width, viewport: viewport, gap: gap)
            if column.windows.contains(id) { return x...(x + width) }
            x += width + gap
        }
        return nil
    }

    /// Lays the row out, sliding the viewport so `focused` is fully visible. Frames of columns
    /// outside the viewport are returned as-is, and the engine decides how to hide them.
    mutating func frames(
        in bounds: CGRect,
        gap: CGFloat,
        focused: WindowID?,
        suspended: Set<WindowID>
    ) -> [WindowID: CGRect] {
        let viewport = bounds.width
        let visible = columns.filter { $0.windows.contains { !suspended.contains($0) } }
        let widths = visible.map { pixelWidth($0.width, viewport: viewport, gap: gap) }
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, visible.count - 1))

        if let focused, let span = span(of: focused, viewport: viewport, gap: gap, suspended: suspended) {
            if span.lowerBound < offset {
                offset = span.lowerBound
            } else if span.upperBound > offset + viewport {
                offset = span.upperBound - viewport
            }
            // Leave room to center the first or last column, but no further.
            let slack = (viewport - (span.upperBound - span.lowerBound)) / 2
            offset = min(max(offset, -slack), max(0, total - viewport) + slack)
        } else {
            offset = min(max(offset, 0), max(0, total - viewport))
        }

        var result: [WindowID: CGRect] = [:]
        var x = bounds.minX - offset
        for (column, width) in zip(visible, widths) {
            let windows = column.windows.filter { !suspended.contains($0) }
            let rects = CGRect(x: x, y: bounds.minY, width: width, height: bounds.height)
                .slices(windows.count, along: .vertical, gap: gap)
            for (window, rect) in zip(windows, rects) { result[window] = rect }
            x += width + gap
        }
        return result
    }

    /// After a window goes away, pull the row back so there is no dead space on the right.
    mutating func tighten(viewport: CGFloat, gap: CGFloat, suspended: Set<WindowID>) {
        let widths = columns
            .filter { $0.windows.contains { !suspended.contains($0) } }
            .map { pixelWidth($0.width, viewport: viewport, gap: gap) }
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1))
        offset = min(max(offset, 0), max(0, total - viewport))
    }
}
