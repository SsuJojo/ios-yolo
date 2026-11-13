import SwiftUI

/// Crosshair and optional rule-of-thirds grid drawn over the camera preview in LiDAR mode.
struct LiDAROverlay: View {
    let gridVisible: Bool

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            if gridVisible {
                var grid = Path()
                for fraction in [1.0 / 3, 2.0 / 3] {
                    grid.move(to: CGPoint(x: size.width * fraction, y: 0))
                    grid.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                    grid.move(to: CGPoint(x: 0, y: size.height * fraction))
                    grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                }
                context.stroke(grid, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            }

            let arm: CGFloat = 28
            let gap: CGFloat = 10
            var cross = Path()
            cross.move(to: CGPoint(x: center.x - arm, y: center.y))
            cross.addLine(to: CGPoint(x: center.x - gap, y: center.y))
            cross.move(to: CGPoint(x: center.x + gap, y: center.y))
            cross.addLine(to: CGPoint(x: center.x + arm, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - arm))
            cross.addLine(to: CGPoint(x: center.x, y: center.y - gap))
            cross.move(to: CGPoint(x: center.x, y: center.y + gap))
            cross.addLine(to: CGPoint(x: center.x, y: center.y + arm))
            context.stroke(cross, with: .color(.mint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            var ring = Path()
            ring.addEllipse(in: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            context.stroke(ring, with: .color(.mint), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}
