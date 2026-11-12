import CoreGraphics
import CoreVideo

enum LiDARRanging {
    static func distances(
        in map: CVPixelBuffer,
        videoSize: CGSize,
        intrinsics: CameraIntrinsics,
        detections: [Detection]
    ) -> [Double?] {
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat16,
              CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess else {
            return Array(repeating: nil, count: detections.count)
        }
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let bytes = CVPixelBufferGetBaseAddress(map) else {
            return Array(repeating: nil, count: detections.count)
        }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let stride = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<UInt16>.stride
        let pixels = bytes.assumingMemoryBound(to: UInt16.self)
        // Video buffers are rotated clockwise for portrait. Depth may still be in sensor orientation.
        let rotate = videoSize.height > videoSize.width && width > height

        return detections.map { detection in
            let box = detection.rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !box.isEmpty else { return nil }
            var samples: [Double] = []
            for row in -2...2 {
                for column in -2...2 {
                    let u = box.midX + CGFloat(column) * box.width * 0.075
                    let v = box.midY + CGFloat(row) * box.height * 0.075
                    let x = min(width - 1, Int((rotate ? v : u) * CGFloat(width)))
                    let y = min(height - 1, Int((rotate ? 1 - u : v) * CGFloat(height)))
                    let z = Double(Float16(bitPattern: pixels[y * stride + x]))
                    guard z.isFinite, z > 0 else { continue }
                    let rx = (Double(u * videoSize.width) - intrinsics.cx) / intrinsics.fx
                    let ry = (Double(v * videoSize.height) - intrinsics.cy) / intrinsics.fy
                    samples.append(z * (1 + rx * rx + ry * ry).squareRoot())
                }
            }
            guard samples.count >= 9 else { return nil }
            samples.sort()
            return samples[samples.count / 2]
        }
    }
}
