import Foundation
import CoreGraphics

struct GridLayout {
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
        guard count > 1 else { return rowMajorFrames }

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

}
