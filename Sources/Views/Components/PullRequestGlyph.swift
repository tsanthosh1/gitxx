import SwiftUI

/// Vector-rendered Git Pull Request icon matching standard Git/GitHub PR branch glyph:
/// Left stem with top and bottom node rings, and right branch curving left into an arrowhead.
public struct PullRequestGlyph: View {
    public var size: CGFloat
    public var color: Color

    public init(size: CGFloat = 16, color: Color = .green) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            
            // Proportional vector metrics
            let strokeW = max(1.6, w * 0.11)
            let nodeRadius = w * 0.155
            let innerRadius = max(0.5, nodeRadius - strokeW * 0.5)

            let cx1 = w * 0.25
            let cx2 = w * 0.75
            let cyTop = h * 0.24
            let cyBot = h * 0.76

            // 1. Left Vertical Line (Connecting Top-Left to Bottom-Left)
            var leftLine = Path()
            leftLine.move(to: CGPoint(x: cx1, y: cyTop + nodeRadius))
            leftLine.addLine(to: CGPoint(x: cx1, y: cyBot - nodeRadius))
            context.stroke(
                leftLine,
                with: .color(color),
                style: StrokeStyle(lineWidth: strokeW, lineCap: .round)
            )

            // 2. Right Branch Line (Rises from Bottom-Right and curves 90° Left)
            let cornerR = w * 0.25
            let arrowTipX = cx1 + nodeRadius + w * 0.08
            var rightBranch = Path()
            rightBranch.move(to: CGPoint(x: cx2, y: cyBot - nodeRadius))
            rightBranch.addLine(to: CGPoint(x: cx2, y: cyTop + cornerR))
            rightBranch.addQuadCurve(
                to: CGPoint(x: cx2 - cornerR, y: cyTop),
                control: CGPoint(x: cx2, y: cyTop)
            )
            rightBranch.addLine(to: CGPoint(x: arrowTipX, y: cyTop))
            context.stroke(
                rightBranch,
                with: .color(color),
                style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round)
            )

            // 3. Arrowhead pointing Left at (arrowTipX, cyTop)
            let arrowBarb = w * 0.15
            var arrow = Path()
            arrow.move(to: CGPoint(x: arrowTipX + arrowBarb, y: cyTop - arrowBarb * 0.82))
            arrow.addLine(to: CGPoint(x: arrowTipX, y: cyTop))
            arrow.addLine(to: CGPoint(x: arrowTipX + arrowBarb, y: cyTop + arrowBarb * 0.82))
            context.stroke(
                arrow,
                with: .color(color),
                style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round)
            )

            // 4. Three Circular Node Rings (Hollow Centers)
            let nodeCenters = [
                CGPoint(x: cx1, y: cyTop),
                CGPoint(x: cx1, y: cyBot),
                CGPoint(x: cx2, y: cyBot)
            ]
            for pt in nodeCenters {
                var ring = Path()
                ring.addEllipse(in: CGRect(
                    x: pt.x - innerRadius,
                    y: pt.y - innerRadius,
                    width: innerRadius * 2,
                    height: innerRadius * 2
                ))
                context.stroke(
                    ring,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: strokeW)
                )
            }
        }
        .frame(width: size, height: size)
    }
}
