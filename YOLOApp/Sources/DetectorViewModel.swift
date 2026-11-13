import Combine
import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore
import simd

struct FrameStats {
    var fps: Double = 0
    var inferenceMs: Double = 0
    var postprocessMs: Double = 0
    var objectCount = 0
    var tagMs: Double = 0
    var tagCount = 0
    var intrinsicsFromCamera = false
}

enum DetectionMode: String, CaseIterable, Identifiable {
    case yolo
    case aprilTag
    case both
    case lidar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yolo: return "YOLO"
        case .aprilTag: return "AprilTag"
        case .both: return "同时"
        case .lidar: return "LiDAR"
        }
    }

    var runsYOLO: Bool { self != .aprilTag && self != .lidar }
    var runsAprilTag: Bool { self == .aprilTag || self == .both }
    var runsLiDAR: Bool { self == .lidar }
}

/// A crosshair reading frozen by the user. Camera coordinates were captured at pin time;
/// `worldPosition` (when ARKit tracking is available) is anchored in the room and stays put
/// as the device moves.
struct PinnedPoint: Identifiable, Equatable {
    let id = UUID()
    let probe: LiDARProbe
    /// World-space position from ARKit at pin time; nil when using AVCapture-only ranging.
    var worldPosition: simd_float3?
    let time: Date

    static func == (lhs: PinnedPoint, rhs: PinnedPoint) -> Bool { lhs.id == rhs.id }
}

struct BenchmarkResult: Identifiable {
    let mode: ComputeMode
    var loadMs: Double?
    var stats: BenchmarkStats?
    var breakdown: DeviceBreakdown?
    var error: String?

    var id: String { mode.id }
}

final class DetectorViewModel: ObservableObject {
    let models = ModelInfo.bundled()
    let camera = CameraManager()

    @Published var selectedModel: ModelInfo? {
        didSet { if selectedModel != oldValue { loadModel() } }
    }
    @Published var computeMode: ComputeMode = .neuralEngine {
        didSet { if computeMode != oldValue { loadModel() } }
    }
    @Published var confidence: Double = 0.25 {
        didSet {
            let value = Float(confidence)
            camera.videoQueue.async { self.confidenceThreshold = value }
        }
    }

    @Published var detectionMode: DetectionMode = .yolo {
        didSet {
            let mode = detectionMode
            camera.videoQueue.async {
                self.activeMode = mode
                if !mode.runsAprilTag { self.tagTracker.reset() }
            }
            DispatchQueue.main.async { self.updateMeshSession(for: mode) }
        }
    }
    /// Edge length of the tag's outer black square, in centimeters.
    @Published var tagSizeCM: Double = 6.9 {
        didSet {
            let meters = tagSizeCM / 100
            camera.videoQueue.async { self.activeTagSize = meters }
        }
    }
    /// AprilTag pose smoothing, 0 = most responsive, 1 = steadiest.
    @Published var tagSmoothing: Double = 0.5 {
        didSet {
            let value = tagSmoothing
            camera.videoQueue.async { self.tagTracker.smoothing = value }
        }
    }
    @Published var tagOrientation: TagPatternOrientation = .rotated180 {
        didSet {
            let orientation = tagOrientation
            camera.videoQueue.async {
                self.activeTagOrientation = orientation
                self.tagTracker.reset()
            }
        }
    }

    /// Live crosshair reading in LiDAR mode; nil when depth is unavailable.
    @Published private(set) var lidarProbe: LiDARProbe?
    /// True when the capture device is delivering a LiDAR depth map.
    @Published private(set) var lidarAvailable = false
    @Published private(set) var pinnedPoints: [PinnedPoint] = []

    // Spatial-mesh (ARKit scene reconstruction) state.
    let mesh = ARMeshController()
    /// True while the LiDAR mode runs its world-anchored spatial mesh scan.
    @Published private(set) var meshActive = false
    @Published private(set) var meshAnchors = 0
    @Published private(set) var meshTriangles = 0

    @Published private(set) var detections: [Detection] = []
    @Published private(set) var tags: [TagOverlay] = []
    @Published private(set) var imageSize = CGSize(width: 1080, height: 1920)
    @Published private(set) var videoRotationAngle: CGFloat = 90
    @Published private(set) var stats = FrameStats()
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?

    @Published private(set) var benchmarkResults: [BenchmarkResult] = []
    @Published private(set) var isBenchmarking = false

    private let loadQueue = DispatchQueue(label: "yolo.model.load", qos: .userInitiated)
    private var loadGeneration = 0
    private var hasStarted = false

    /// Freezes the current crosshair reading. When the spatial mesh is active the point is
    /// also anchored in world space, so distances stay valid after the device moves.
    func pinLiDARPoint() {
        guard let probe = lidarProbe else { return }
        let world = meshActive ? mesh.crosshairWorldPosition() : nil
        pinnedPoints.append(PinnedPoint(probe: probe, worldPosition: world, time: Date()))
    }

    func clearPinnedPoints() {
        pinnedPoints.removeAll()
    }

    // Confined to camera.videoQueue.
    private var detector: YOLODetector?
    private var confidenceThreshold: Float = 0.25
    private var isPaused = false
    private var activeMode: DetectionMode = .yolo
    private var activeTagSize = 0.069
    private var activeTagOrientation: TagPatternOrientation = .rotated180
    private lazy var tagDetector = AprilTagDetector()
    private let tagTracker = AprilTagTracker()
    private var lastFrameTime: CFTimeInterval = 0
    private var smoothedFPS: Double = 0

    init() {
        selectedModel = models.first
        camera.onFrame = { [weak self] frame in self?.process(frame) }
        camera.onRotationChange = { [weak self] angle in
            if let self, self.videoRotationAngle != angle { self.videoRotationAngle = angle }
        }
        bindMesh()
    }

    /// Mirrors the ARMeshController's published stats and crosshair probe into this model.
    private func bindMesh() {
        mesh.$probe
            .receive(on: DispatchQueue.main)
            .sink { [weak self] probe in
                guard let self, self.detectionMode == .lidar else { return }
                self.lidarProbe = probe
                self.lidarAvailable = probe != nil
            }
            .store(in: &meshCancellables)
        mesh.$anchorCount
            .receive(on: DispatchQueue.main)
            .assign(to: &$meshAnchors)
        mesh.$triangleCount
            .receive(on: DispatchQueue.main)
            .assign(to: &$meshTriangles)
    }

    private var meshCancellables = Set<AnyCancellable>()

    func start() {
        camera.start { [weak self] error in
            if let error { self?.errorMessage = error }
        }
        if !hasStarted {
            hasStarted = true
            loadModel()
        }
    }

    /// Runs the ARKit spatial-mesh scan only in LiDAR mode, and only on devices that
    /// support it. ARKit and AVCapture cannot share the camera, so the capture session
    /// stops while the mesh runs and restarts when leaving LiDAR mode.
    private func updateMeshSession(for mode: DetectionMode) {
        guard mode.runsLiDAR else {
            if meshActive {
                mesh.pause()
                meshActive = false
                camera.start { [weak self] error in
                    if let error { self?.errorMessage = error }
                }
            }
            return
        }
        guard ARMeshController.isSupported else {
            errorMessage = "此设备不支持 ARKit 场景重建，无法显示空间网格；准星测距仍可用"
            return
        }
        if !meshActive {
            camera.stop { [weak self] in
                guard let self else { return }
                self.mesh.run()
                self.meshActive = true
            }
        }
    }

    /// Clears the spatial mesh scan and the world-anchored pinned points, restarting a fresh scan.
    func clearSpatialMesh() {
        pinnedPoints.removeAll()
        guard meshActive else { return }
        mesh.stopAndClear()
        mesh.run()
    }

    // MARK: - Model loading

    private func loadModel() {
        guard let model = selectedModel else {
            errorMessage = "App 内没有模型，请检查构建流程中的模型导出步骤"
            return
        }
        let mode = computeMode
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        statusMessage = nil

        loadQueue.async {
            let result = Result { try YOLODetector(info: model, computeMode: mode) }
            if case let .success(detector) = result {
                self.camera.videoQueue.async {
                    self.detector = detector
                    self.smoothedFPS = 0
                }
            }
            DispatchQueue.main.async {
                guard generation == self.loadGeneration else { return }
                self.isLoading = false
                switch result {
                case let .success(detector):
                    self.errorMessage = nil
                    self.statusMessage = String(format: "%@ 已加载到 %@，用时 %.0f ms", model.name, mode.title, detector.loadTime * 1000)
                case let .failure(error):
                    self.errorMessage = "模型加载失败：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Per-frame processing (camera.videoQueue)

    private func process(_ frame: CameraFrame) {
        guard !isPaused else { return }
        let pixelBuffer = frame.pixelBuffer
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        var stats = FrameStats()
        var detections: [Detection] = []
        var tags: [TagOverlay] = []
        var probe: LiDARProbe?
        var failure: String?

        if activeMode.runsYOLO, let detector {
            do {
                let result = try detector.detect(pixelBuffer: pixelBuffer, confidence: confidenceThreshold)
                detections = result.detections
                if frame.lidarEnabled {
                    let depths = frame.depth.map {
                        LiDARRanging.distances(
                            in: $0,
                            videoSize: size,
                            rotationAngle: frame.rotationAngle,
                            intrinsics: frame.intrinsics,
                            detections: detections
                        )
                    }
                    for index in detections.indices {
                        let distance = depths?[index] ?? nil
                        detections[index].distanceReading = distance.map(DistanceReading.meters) ?? .unavailable
                    }
                }
                stats.inferenceMs = result.inferenceMs
                stats.postprocessMs = result.postprocessMs
                stats.objectCount = result.detections.count
            } catch {
                failure = "推理失败：\(error.localizedDescription)"
            }
        }

        if activeMode.runsLiDAR, let depth = frame.depth, !ARMeshController.isSupported {
            // Only probe from AVCapture depth when the ARKit mesh can't own the camera;
            // otherwise bindMesh() supplies the probe from ARKit scene depth.
            probe = LiDARRanging.probe(
                in: depth,
                videoSize: size,
                rotationAngle: frame.rotationAngle,
                intrinsics: frame.intrinsics
            )
        }

        if activeMode.runsAprilTag {
            let start = CACurrentMediaTime()
            let found = tagDetector.detect(pixelBuffer: pixelBuffer, intrinsics: frame.intrinsics, tagSize: activeTagSize)
            tags = tagTracker.update(
                with: found,
                timestamp: frame.timestamp.isFinite ? frame.timestamp : start,
                intrinsics: frame.intrinsics,
                imageSize: size,
                tagSize: activeTagSize,
                orientation: activeTagOrientation
            )
            stats.tagMs = (CACurrentMediaTime() - start) * 1000
            stats.tagCount = found.count
            stats.intrinsicsFromCamera = frame.intrinsics.isFromCamera
        }

        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let instant = 1 / max(now - lastFrameTime, 1e-6)
            smoothedFPS = smoothedFPS == 0 ? instant : smoothedFPS * 0.9 + instant * 0.1
        }
        lastFrameTime = now
        stats.fps = smoothedFPS

        let lidarEnabled = frame.lidarEnabled
        DispatchQueue.main.async {
            self.detections = detections
            self.tags = tags
            self.lidarProbe = probe
            self.lidarAvailable = lidarEnabled
            self.imageSize = size
            self.stats = stats
            if let failure { self.errorMessage = failure }
        }
    }
    // MARK: - Benchmark

    /// Loads the selected model on NPU, GPU and CPU in turn and times raw predictions.
    func runBenchmark(iterations: Int = 50) {
        guard let model = selectedModel, !isBenchmarking else { return }
        isBenchmarking = true
        benchmarkResults = []
        camera.videoQueue.async {
            self.isPaused = true
            self.tagTracker.reset()
            DispatchQueue.main.async {
                self.detections = []
                self.tags = []
            }
        }

        Task.detached(priority: .userInitiated) {
            for mode in [ComputeMode.neuralEngine, .gpu, .cpu] {
                var result = BenchmarkResult(mode: mode)
                do {
                    let detector = try YOLODetector(info: model, computeMode: mode)
                    result.loadMs = detector.loadTime * 1000
                    result.stats = try detector.benchmark(iterations: iterations, warmup: 5)
                } catch {
                    result.error = error.localizedDescription
                }
                result.breakdown = await ComputePlanInspector.breakdown(modelURL: model.url, mode: mode)
                let finished = result
                await MainActor.run { self.benchmarkResults.append(finished) }
            }
            await MainActor.run { self.isBenchmarking = false }
            self.camera.videoQueue.async {
                self.isPaused = false
                self.lastFrameTime = 0
            }
        }
    }
}
