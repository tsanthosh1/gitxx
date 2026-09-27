import SwiftUI

/// Vector prompt icon `> _` representing the terminal prompt for the Command Palette,
/// matching the exact terminal prompt chevron and cursor design.
public struct CommandPalettePromptIcon: View {
    public var size: CGFloat
    public var strokeWidth: CGFloat?

    public init(size: CGFloat = 13, strokeWidth: CGFloat? = nil) {
        self.size = size
        self.strokeWidth = strokeWidth
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let lw = strokeWidth ?? max(1.5, min(w, h) * 0.118)
            let stroke = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)

            // 1. Prompt Chevron '>'
            var chevronPath = Path()
            chevronPath.move(to: CGPoint(x: w * 0.14, y: h * 0.20))
            chevronPath.addLine(to: CGPoint(x: w * 0.48, y: h * 0.51))
            chevronPath.addLine(to: CGPoint(x: w * 0.14, y: h * 0.82))
            context.stroke(chevronPath, with: .foreground, style: stroke)

            // 2. Baseline Cursor '_'
            var cursorPath = Path()
            cursorPath.move(to: CGPoint(x: w * 0.54, y: h * 0.82))
            cursorPath.addLine(to: CGPoint(x: w * 0.88, y: h * 0.82))
            context.stroke(cursorPath, with: .foreground, style: stroke)
        }
        .frame(width: size, height: size)
    }
}

/// Backwards-compatibility alias
public typealias CommandPaletteIconView = CommandPalettePromptIcon
