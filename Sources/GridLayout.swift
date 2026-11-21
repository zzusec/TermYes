import Foundation
import CoreGraphics

struct GridLayout {
    static func advancedClockwise<Element>(_ values: [Element]) -> [Element] {
        guard values.count > 1, let last = values.last else { return values }
        return [last] + values.dropLast()
    }

    static func frames(count: Int, within bounds: CGRect, gap: CGFloat = 10) -> [CGRect] {
        guard count > 0, bounds.width > 0, bounds.height > 0 else { return [] }

        let clampedGap = max(0, min(gap, min(bounds.width, bounds.height) / 8))
        let outerBounds = bounds.insetBy(dx: clampedGap, dy: clampedGap)
        let usesTwoColumnOddLayout = count > 1 && !count.isMultiple(of: 2)
        let columnCount = usesTwoColumnOddLayout ? 2 : Int(ceil(sqrt(Double(count))))
        let rowCount = Int(ceil(Double(count) / Double(columnCount)))

        if usesTwoColumnOddLayout {
            let leftCount = (count + 1) / 2
            let rightCount = count / 2
            let usableWidth = max(1, outerBounds.width - clampedGap)
            let rawCellWidth = usableWidth / 2
            let leftX = outerBounds.minX.rounded()
            let leftRight = (outerBounds.minX + rawCellWidth).rounded()
            let rightX = (outerBounds.minX + rawCellWidth + clampedGap).rounded()
            let rightRight = outerBounds.maxX.rounded()

            func columnFrames(itemCount: Int, x: CGFloat, width: CGFloat) -> [CGRect] {
                let usableHeight = max(1, outerBounds.height - clampedGap * CGFloat(max(0, itemCount - 1)))
                let rawHeight = usableHeight / CGFloat(itemCount)

                return (0..<itemCount).map { row in
                    let rowTop = outerBounds.maxY - CGFloat(row) * rawHeight - CGFloat(row) * clampedGap
                    let rowBottom = outerBounds.maxY - CGFloat(row + 1) * rawHeight - CGFloat(row) * clampedGap
                    let roundedTop = rowTop.rounded()
                    let roundedBottom = rowBottom.rounded()

                    return CGRect(
                        x: x,
                        y: roundedBottom,
                        width: max(1, width),
                        height: max(1, roundedTop - roundedBottom)
                    )
                }
            }

            return columnFrames(
                itemCount: leftCount,
                x: leftX,
                width: leftRight - leftX
            ) + columnFrames(
                itemCount: rightCount,
                x: rightX,
                width: rightRight - rightX
            )
        }

        let usableHeight = max(1, outerBounds.height - clampedGap * CGFloat(max(0, rowCount - 1)))
        let rawRowHeight = usableHeight / CGFloat(rowCount)

        var result: [CGRect] = []
        var remaining = count

        for row in 0..<rowCount {
            let itemsInRow = min(columnCount, remaining)
            guard itemsInRow > 0 else { break }

            let rowTop = outerBounds.maxY - CGFloat(row) * rawRowHeight - CGFloat(row) * clampedGap
            let rowBottom = outerBounds.maxY - CGFloat(row + 1) * rawRowHeight - CGFloat(row) * clampedGap
            let roundedTop = rowTop.rounded()
            let roundedBottom = rowBottom.rounded()
            let rowHeight = max(1, roundedTop - roundedBottom)

            let usableWidth = max(1, outerBounds.width - clampedGap * CGFloat(max(0, itemsInRow - 1)))
            let rawCellWidth = usableWidth / CGFloat(itemsInRow)

            for column in 0..<itemsInRow {
                let cellLeft = outerBounds.minX + CGFloat(column) * rawCellWidth + CGFloat(column) * clampedGap
                let cellRight = outerBounds.minX + CGFloat(column + 1) * rawCellWidth + CGFloat(column) * clampedGap
                let roundedLeft = cellLeft.rounded()
                let roundedRight = cellRight.rounded()

                result.append(
                    CGRect(
                        x: roundedLeft,
                        y: roundedBottom,
                        width: max(1, roundedRight - roundedLeft),
                        height: rowHeight
                    )
                )
            }
            remaining -= itemsInRow
        }
        return result
    }
    static func clockwiseFrames(count: Int, within bounds: CGRect, gap: CGFloat = 10) -> [CGRect] {
        let rowMajorFrames = frames(count: count, within: bounds, gap: gap)
        guard count > 1, rowMajorFrames.count == count else { return rowMajorFrames }

        if !count.isMultiple(of: 2) {
            let leftCount = (count + 1) / 2
            let leftFrames = Array(rowMajorFrames[0..<leftCount])
            let rightFrames = Array(rowMajorFrames[leftCount...])
            return [leftFrames[0]] + rightFrames + leftFrames.dropFirst().reversed()
        }

        let columnCount = Int(ceil(sqrt(Double(count))))
        var result: [CGRect] = []
        var index = 0
        var row = 0

        while index < rowMajorFrames.count {
            let itemsInRow = min(columnCount, rowMajorFrames.count - index)
            let rowFrames = Array(rowMajorFrames[index..<(index + itemsInRow)])
            result.append(contentsOf: row.isMultiple(of: 2) ? rowFrames : rowFrames.reversed())
            index += itemsInRow
            row += 1
        }
        return result
    }

    /// Packs Terminal windows that snapped downward to integer character cells so neighboring
    /// columns and rows touch with zero gap while preserving each window's snapped cell size.
    static func packTopLeftSnappedFrames(
        snapped: [CGRect],
        slots: [CGRect],
        within screenBounds: CGRect
    ) -> [CGRect] {
        let count = snapped.count
        guard count > 1,
              slots.count == count,
              screenBounds.width > 0,
              screenBounds.height > 0 else { return snapped }

        var packed = snapped
        let usesTwoColumnOddLayout = !count.isMultiple(of: 2)

        if usesTwoColumnOddLayout {
            let minSlotX = slots.map(\.minX).min() ?? screenBounds.minX
            let maxSlotX = slots.map(\.minX).max() ?? screenBounds.maxX
            let splitX = (minSlotX + maxSlotX) / 2

            let leftIndices = slots.indices
                .filter { slots[$0].minX <= splitX }
                .sorted { slots[$0].minY < slots[$1].minY }
            let rightIndices = slots.indices
                .filter { slots[$0].minX > splitX }
                .sorted { slots[$0].minY < slots[$1].minY }

            guard !leftIndices.isEmpty, !rightIndices.isEmpty else { return snapped }

            let leftWidth = leftIndices.map { snapped[$0].width.rounded() }.max() ?? 0
            let rightWidth = rightIndices.map { snapped[$0].width.rounded() }.max() ?? 0
            let totalWidth = leftWidth + rightWidth
            let startX = max(
                screenBounds.minX.rounded(),
                (screenBounds.minX + floor((screenBounds.width - totalWidth) / 2)).rounded()
            )
            let seamX = startX + leftWidth

            var currentLeftY = screenBounds.minY.rounded()
            for index in leftIndices {
                let w = snapped[index].width.rounded()
                let h = snapped[index].height.rounded()
                packed[index] = CGRect(x: seamX - w, y: currentLeftY, width: w, height: h)
                currentLeftY += h
            }

            var currentRightY = screenBounds.minY.rounded()
            for index in rightIndices {
                let w = snapped[index].width.rounded()
                let h = snapped[index].height.rounded()
                packed[index] = CGRect(x: seamX, y: currentRightY, width: w, height: h)
                currentRightY += h
            }
            return packed
        }

        // Even counts use row-major bands; group indices into top-to-bottom rows by slot minY.
        let sortedByY = slots.indices.sorted {
            abs(slots[$0].minY - slots[$1].minY) > 1.5
                ? slots[$0].minY < slots[$1].minY
                : slots[$0].minX < slots[$1].minX
        }
        var rows: [[Int]] = []
        for index in sortedByY {
            if let lastRow = rows.last,
               let sample = lastRow.first,
               abs(slots[sample].minY - slots[index].minY) <= 1.5 {
                rows[rows.count - 1].append(index)
            } else {
                rows.append([index])
            }
        }
        guard !rows.isEmpty else { return snapped }

        let firstRowCount = rows[0].count
        let uniformColumns = firstRowCount > 0 && rows.allSatisfy { $0.count == firstRowCount }

        if uniformColumns {
            let colWidths: [CGFloat] = (0..<firstRowCount).map { col in
                rows.map { snapped[$0[col]].width.rounded() }.max() ?? 0
            }
            let totalWidth = colWidths.reduce(0, +)
            let startX = max(
                screenBounds.minX.rounded(),
                (screenBounds.minX + floor((screenBounds.width - totalWidth) / 2)).rounded()
            )
            var colOrigins: [CGFloat] = []
            var runningX = startX
            for width in colWidths {
                colOrigins.append(runningX)
                runningX += width
            }

            var currentY = screenBounds.minY.rounded()
            for row in rows {
                let rowHeight = row.map { snapped[$0].height.rounded() }.max() ?? 0
                for (col, index) in row.enumerated() {
                    let w = snapped[index].width.rounded()
                    let h = snapped[index].height.rounded()
                    let x: CGFloat
                    if firstRowCount == 2 && col == 0 {
                        x = colOrigins[1] - w
                    } else {
                        x = colOrigins[col]
                    }
                    packed[index] = CGRect(x: x, y: currentY, width: w, height: h)
                }
                currentY += rowHeight
            }
            return packed
        }

        var currentY = screenBounds.minY.rounded()
        for row in rows {
            let rowHeight = row.map { snapped[$0].height.rounded() }.max() ?? 0
            let rowWidth = row.map { snapped[$0].width.rounded() }.reduce(0, +)
            var runningX = max(
                screenBounds.minX.rounded(),
                (screenBounds.minX + floor((screenBounds.width - rowWidth) / 2)).rounded()
            )
            for index in row {
                let w = snapped[index].width.rounded()
                let h = snapped[index].height.rounded()
                packed[index] = CGRect(x: runningX, y: currentY, width: w, height: h)
                runningX += w
            }
            currentY += rowHeight
        }
        return packed
    }

}
