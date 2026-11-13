import SwiftUI

/// Crosshair drawn over the spatial mesh / camera preview in LiDAR mode.
/// The world-anchored white grid itself is rendered by `ARMeshController`.
struct LiDAROverlay: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

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
