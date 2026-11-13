import CoreGraphics
import CoreVideo

/// One crosshair reading. Coordinates are in the camera frame, meters:
/// X to the right, Y up, Z straight out of the lens (depth along the optical axis).
struct LiDARProbe: Equatable {
    var range: Double
    var x: Double
    var y: Double
    var z: Double

    func distance(to other: LiDARProbe) -> Double {
        let dx = x - other.x, dy = y - other.y, dz = z - other.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}

enum LiDARRanging {
    /// Maps a point of the upright video frame (0...1) to the depth map, which stays in the sensor's landscape orientation.
    private static func sensorCoordinate(u: CGFloat, v: CGFloat, rotation: Int) -> (CGFloat, CGFloat) {
        switch rotation {
        case 90: return (v, 1 - u)
        case 180: return (1 - u, 1 - v)
        case 270: return (1 - v, u)
        default: return (u, v)
        }
    }

    /// Median depth around `point` (normalized, upright video frame), converted to camera-frame XYZ and line-of-sight range.
    static func probe(
        in map: CVPixelBuffer,
        videoSize: CGSize,
        rotationAngle: CGFloat,
        intrinsics: CameraIntrinsics,
        at point: CGPoint = CGPoint(x: 0.5, y: 0.5),
        spread: CGSize = CGSize(width: 0.006, height: 0.006)
    ) -> LiDARProbe? {
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat16,
              CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let stride = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<UInt16>.stride
        let pixels = bytes.assumingMemoryBound(to: UInt16.self)
        let rotation = Int(rotationAngle.rounded()) % 360

        var samples: [(z: Double, rx: Double, ry: Double)] = []
        for row in -2...2 {
            for column in -2...2 {
                let u = point.x + CGFloat(column) * spread.width
                let v = point.y + CGFloat(row) * spread.height
                guard (0...1).contains(u), (0...1).contains(v) else { continue }
                let (sensorU, sensorV) = sensorCoordinate(u: u, v: v, rotation: rotation)
                let px = min(width - 1, max(0, Int(sensorU * CGFloat(width))))
                let py = min(height - 1, max(0, Int(sensorV * CGFloat(height))))
                let z = Double(Float16(bitPattern: pixels[py * stride + px]))
                guard z.isFinite, z > 0 else { continue }
                samples.append((
                    z,
                    (Double(u * videoSize.width) - intrinsics.cx) / intrinsics.fx,
                    (Double(v * videoSize.height) - intrinsics.cy) / intrinsics.fy
                ))
            }
        }
        guard samples.count >= 9 else { return nil }
        // Same estimator as before: median of the line-of-sight ranges.
        let ranged = samples.map { (sample: $0, range: $0.z * (1 + $0.rx * $0.rx + $0.ry * $0.ry).squareRoot()) }
            .sorted { $0.range < $1.range }
        let m = ranged[ranged.count / 2]
        return LiDARProbe(
            range: m.range,
            x: m.sample.rx * m.sample.z,
            y: -m.sample.ry * m.sample.z,
            z: m.sample.z
        )
    }

    static func distances(
        in map: CVPixelBuffer,
        videoSize: CGSize,
        rotationAngle: CGFloat,
        intrinsics: CameraIntrinsics,
        detections: [Detection]
    ) -> [Double?] {
        detections.map { detection in
            let box = detection.rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !box.isEmpty else { return nil }
            // The sample grid scales with the box, as before: 5x5 points spaced 7.5% of the box size.
            let spread = CGSize(width: box.width * 0.075, height: box.height * 0.075)
            return probe(
                in: map,
                videoSize: videoSize,
                rotationAngle: rotationAngle,
                intrinsics: intrinsics,
                at: CGPoint(x: box.midX, y: box.midY),
                spread: spread
            )?.range
        }
    }
}
