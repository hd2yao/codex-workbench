import CoreGraphics

public enum ChartCalloutDirection: Equatable, Sendable {
    case above
    case below
}

public struct ChartCalloutPlacementResult: Equatable, Sendable {
    public let center: CGPoint
    public let direction: ChartCalloutDirection
    public let fits: Bool

    public init(center: CGPoint, direction: ChartCalloutDirection, fits: Bool) {
        self.center = center
        self.direction = direction
        self.fits = fits
    }
}

public enum ChartCalloutPlacement {
    public static func place(
        point: CGPoint,
        calloutSize: CGSize,
        plotFrame: CGRect,
        horizontalInset: CGFloat = 8,
        verticalInset: CGFloat = 4,
        gap: CGFloat = 14
    ) -> ChartCalloutPlacementResult {
        let direction: ChartCalloutDirection = point.y < plotFrame.midY ? .below : .above
        let requiredWidth = calloutSize.width + horizontalInset * 2
        let requiredHeight = calloutSize.height + verticalInset * 2

        guard plotFrame.width >= requiredWidth, plotFrame.height >= requiredHeight else {
            return ChartCalloutPlacementResult(
                center: CGPoint(x: plotFrame.midX, y: plotFrame.midY),
                direction: direction,
                fits: false
            )
        }

        let minimumX = plotFrame.minX + calloutSize.width / 2 + horizontalInset
        let maximumX = plotFrame.maxX - calloutSize.width / 2 - horizontalInset
        let x = min(max(point.x, minimumX), maximumX)

        let preferredY: CGFloat
        switch direction {
        case .above:
            preferredY = point.y - gap - calloutSize.height / 2
        case .below:
            preferredY = point.y + gap + calloutSize.height / 2
        }
        let minimumY = plotFrame.minY + calloutSize.height / 2 + verticalInset
        let maximumY = plotFrame.maxY - calloutSize.height / 2 - verticalInset
        let y = min(max(preferredY, minimumY), maximumY)

        return ChartCalloutPlacementResult(
            center: CGPoint(x: x, y: y),
            direction: direction,
            fits: true
        )
    }
}
