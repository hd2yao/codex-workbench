import CodexWorkbenchCore
import CoreGraphics

func runChartCalloutPlacementTests(_ runner: inout TestRunner) {
    let plot = CGRect(x: 20, y: 30, width: 400, height: 220)
    let callout = CGSize(width: 140, height: 72)

    let peak = ChartCalloutPlacement.place(
        point: CGPoint(x: 220, y: 38),
        calloutSize: callout,
        plotFrame: plot
    )
    runner.expect(peak.direction == .below, "Peak callouts should prefer the space below")
    runner.expect(
        plot.contains(calloutFrame(center: peak.center, size: callout)),
        "Peak callouts should stay inside the plot"
    )

    let zero = ChartCalloutPlacement.place(
        point: CGPoint(x: 220, y: 244),
        calloutSize: callout,
        plotFrame: plot
    )
    runner.expect(zero.direction == .above, "Zero-value callouts should prefer the space above")
    runner.expect(
        plot.contains(calloutFrame(center: zero.center, size: callout)),
        "Zero-value callouts should stay inside the plot"
    )

    let first = ChartCalloutPlacement.place(
        point: CGPoint(x: plot.minX, y: plot.midY),
        calloutSize: callout,
        plotFrame: plot
    )
    runner.expect(
        first.center.x == plot.minX + callout.width / 2 + 8,
        "First-day callouts should be clamped to the leading inset"
    )

    let last = ChartCalloutPlacement.place(
        point: CGPoint(x: plot.maxX, y: plot.midY),
        calloutSize: callout,
        plotFrame: plot
    )
    runner.expect(
        last.center.x == plot.maxX - callout.width / 2 - 8,
        "Last-day callouts should be clamped to the trailing inset"
    )

    let tinyPlot = CGRect(x: 0, y: 0, width: 80, height: 48)
    let oversized = ChartCalloutPlacement.place(
        point: CGPoint(x: 4, y: 4),
        calloutSize: callout,
        plotFrame: tinyPlot
    )
    runner.expect(!oversized.fits, "Oversized callouts should report their fallback state")
    runner.expect(
        oversized.center == CGPoint(x: tinyPlot.midX, y: tinyPlot.midY),
        "Oversized callouts should fall back to the plot center"
    )
}

private func calloutFrame(center: CGPoint, size: CGSize) -> CGRect {
    CGRect(
        x: center.x - size.width / 2,
        y: center.y - size.height / 2,
        width: size.width,
        height: size.height
    )
}
