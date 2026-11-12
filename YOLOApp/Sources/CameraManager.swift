import AVFoundation
import CoreVideo
import simd

/// Pinhole intrinsics in pixels of the delivered (already rotated) frame.
struct CameraIntrinsics {
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    /// True when taken from AVFoundation's per-frame matrix, false when estimated from the field of view.
    var isFromCamera: Bool
}

struct CameraFrame {
    let pixelBuffer: CVPixelBuffer
    let intrinsics: CameraIntrinsics
    /// Presentation time, seconds.
    let timestamp: Double
    let depth: CVPixelBuffer?
    let lidarEnabled: Bool
    /// Clockwise rotation, in degrees, applied to the delivered video buffer.
    let rotationAngle: CGFloat
}

/// Back-camera capture delivering upright 420f (full-range NV12) frames on `videoQueue`.
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureDataOutputSynchronizerDelegate {
    let session = AVCaptureSession()
    let videoQueue = DispatchQueue(label: "yolo.camera.video", qos: .userInitiated)
    /// Called on `videoQueue` for every frame that isn't dropped.
    var onFrame: ((CameraFrame) -> Void)?

    private let sessionQueue = DispatchQueue(label: "yolo.camera.session")
    private let output = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var isConfigured = false
    /// Horizontal field of view of the active format in degrees (along the sensor's long side).
    private var fieldOfView: Float = 70
    /// Applied to the video connection before the first frame; updated by the rotation coordinator afterwards.
    private var pendingRotationAngle: CGFloat = 90
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservations: [NSKeyValueObservation] = []

    /// Called on the main queue when the device's upright rotation angle changes.
    var onRotationChange: ((CGFloat) -> Void)?

    /// Requests permission, configures the session and starts it. `completion` runs on the main queue.
    func start(completion: @escaping (String?) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { completion("未获得相机权限，请在 设置 > 隐私 > 相机 中开启") }
                return
            }
            self.sessionQueue.async {
                if !self.isConfigured {
                    if let error = self.configure() {
                        DispatchQueue.main.async { completion(error) }
                        return
                    }
                    self.isConfigured = true
                }
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure() -> String? {
        let lidar = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
        let formats = lidar?.formats.compactMap { format -> (AVCaptureDevice.Format, AVCaptureDevice.Format)? in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard size.width == 1920, size.height == 1080,
                  CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                  let depth = format.supportedDepthDataFormats.first(where: {
                      CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat16
                  }) else { return nil }
            return (format, depth)
        }
        let lidarFormats = formats?.first
        let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let device = lidarFormats == nil ? wide : lidar else {
            return "找不到后置摄像头"
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .hd1920x1080
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return "无法添加相机输入" }
            session.addInput(input)
        } catch {
            return "相机打开失败：\(error.localizedDescription)"
        }

        // Luma plane feeds AprilTag directly; Vision converts for YOLO.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { return "无法添加视频输出" }
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            applyRotation(pendingRotationAngle, to: connection)
            if connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
        }
        if let (videoFormat, depthFormat) = lidarFormats, session.canAddOutput(depthOutput) {
            do {
                try device.lockForConfiguration()
                device.activeFormat = videoFormat
                device.activeDepthDataFormat = depthFormat
                device.unlockForConfiguration()
            } catch {
                return "无法配置 LiDAR：\(error.localizedDescription)"
            }
            depthOutput.isFilteringEnabled = false
            session.addOutput(depthOutput)
            let sync = AVCaptureDataOutputSynchronizer(dataOutputs: [output, depthOutput])
            sync.setDelegate(self, queue: videoQueue)
            synchronizer = sync
        } else {
            enableHighFrameRate(device, fps: 60)
        }
        fieldOfView = device.activeFormat.videoFieldOfView
        observeRotation(of: device)
        return nil
    }

    private func applyRotation(_ angle: CGFloat, to connection: AVCaptureConnection) {
        guard connection.isVideoRotationAngleSupported(angle), connection.videoRotationAngle != angle else { return }
        connection.videoRotationAngle = angle
    }

    /// Watches the physical device so iPad landscape (including 180° flips) and portrait keep the
    /// video buffers, preview and overlay in the same orientation.
    private func observeRotation(of device: AVCaptureDevice) {
        guard rotationCoordinator == nil else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        rotationObservations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] _, change in
                guard let self = self, let angle = change.newValue else { return }
                if change.isInitial {
                    // The initial callback runs while `configure()` owns `sessionQueue`.
                    self.pendingRotationAngle = angle
                    if let connection = self.output.connection(with: .video) {
                        self.applyRotation(angle, to: connection)
                    }
                } else {
                    self.sessionQueue.async {
                        self.pendingRotationAngle = angle
                        if let connection = self.output.connection(with: .video) {
                            self.applyRotation(angle, to: connection)
                        }
                    }
                }
                DispatchQueue.main.async { self.onRotationChange?(angle) }
            },
        ]
    }

    /// Picks a 1080p format that supports `fps` so the camera doesn't cap the measured FPS at 30.
    private func enableHighFrameRate(_ device: AVCaptureDevice, fps: Double) {
        let format = device.formats.first { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width == 1920 && dims.height == 1080
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps }
        }
        guard let format, (try? device.lockForConfiguration()) != nil else { return }
        device.activeFormat = format
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        deliver(sampleBuffer, depth: nil, lidarEnabled: false)
    }

    func dataOutputSynchronizer(
        _ synchronizer: AVCaptureDataOutputSynchronizer,
        didOutput data: AVCaptureSynchronizedDataCollection
    ) {
        guard let video = data.synchronizedData(for: output) as? AVCaptureSynchronizedSampleBufferData,
              !video.sampleBufferWasDropped else { return }
        let depth = data.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData
        let map = depth.flatMap { $0.depthDataWasDropped ? nil : $0.depthData.depthDataMap }
        deliver(video.sampleBuffer, depth: map, lidarEnabled: true)
    }

    private func deliver(_ sampleBuffer: CMSampleBuffer, depth: CVPixelBuffer?, lidarEnabled: Bool) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let height = Double(CVPixelBufferGetHeight(pixelBuffer))
        let rotation = output.connection(with: .video)?.videoRotationAngle ?? 90
        let matrix = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data
        let intrinsics = matrix.flatMap { parseIntrinsics($0, width: width, height: height, rotation: rotation) }
            ?? estimatedIntrinsics(width: width, height: height)
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        onFrame?(CameraFrame(
            pixelBuffer: pixelBuffer,
            intrinsics: intrinsics,
            timestamp: timestamp,
            depth: depth,
            lidarEnabled: lidarEnabled,
            rotationAngle: rotation
        ))
    }

    private func parseIntrinsics(_ data: Data, width: Double, height: Double, rotation: CGFloat) -> CameraIntrinsics? {
        guard data.count >= MemoryLayout<matrix_float3x3>.size else { return nil }
        let m = data.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
        var fx = Double(m.columns.0.x), fy = Double(m.columns.1.y)
        var cx = Double(m.columns.2.x), cy = Double(m.columns.2.y)
        // Usually the matrix describes the unrotated landscape sensor; rotate it like the delivered
        // frame. If the matrix already matches the frame's aspect, leave it alone.
        let rotated = Int(rotation.rounded()) % 360
        let sensorWidth = (rotated == 90 || rotated == 270) ? height : width
        let sensorHeight = (rotated == 90 || rotated == 270) ? width : height
        if (cx > cy) != (width > height) {
            switch rotated {
            case 90:
                (fx, fy, cx, cy) = (fy, fx, width - cy, cx)
            case 180:
                (cx, cy) = (sensorWidth - cx, sensorHeight - cy)
            case 270:
                (fx, fy, cx, cy) = (fy, fx, cy, sensorWidth - cx)
            default:
                break
            }
        }
        let plausible = fx > 0 && fy > 0 && abs(cx - width / 2) < width * 0.2 && abs(cy - height / 2) < height * 0.2
        return plausible ? CameraIntrinsics(fx: fx, fy: fy, cx: cx, cy: cy, isFromCamera: true) : nil
    }

    private func estimatedIntrinsics(width: Double, height: Double) -> CameraIntrinsics {
        let focal = max(width, height) / 2 / tan(Double(fieldOfView) * .pi / 360)
        return CameraIntrinsics(fx: focal, fy: focal, cx: width / 2, cy: height / 2, isFromCamera: false)
    }
}
