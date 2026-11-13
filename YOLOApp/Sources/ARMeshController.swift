import ARKit
import Combine
import SceneKit
import SwiftUI
import UIKit

/// World-anchored spatial mesh from ARKit Scene Reconstruction.
///
/// ARKit keeps an incrementally refined, world-anchored mesh of scanned surfaces. Each
/// `ARMeshAnchor` is rendered as a white line grid over the real surfaces, so the grid
/// stays glued to objects and never disappears when the view angle moves — it is a
/// persistent cache of the scanned room, not a per-frame effect.
final class ARMeshController: NSObject, ObservableObject, ARSessionDelegate, ARSCNViewDelegate {
    let session = ARSession()
    let scene = SCNScene()

    /// Toggles the white wireframe without stopping the scan.
    @Published var meshVisible = true {
        didSet { guard meshVisible != oldValue else { return }; applyVisibility() }
    }
    /// Percentage of triangle edges drawn, 10...100. Lower is lighter to render.
    @Published var meshDensity: Double = 70 {
        didSet {
            let clamped = min(max(meshDensity, 10), 100)
            if clamped != meshDensity { meshDensity = clamped; return }
            rebuildAllGeometry()
        }
    }

    @Published private(set) var anchorCount = 0
    @Published private(set) var triangleCount = 0
    /// Live crosshair reading in camera coordinates (X right, Y up, Z forward), meters.
    @Published private(set) var probe: LiDARProbe?
    @Published private(set) var arAvailable = false

    /// True on LiDAR devices (iPhone Pro / iPad Pro) that support scene reconstruction.
    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics([.sceneDepth])
    }

    private let lock = NSLock()
    /// Copied geometry per anchor id; doubles as the cache for density rebuilds. ARKit reuses
    /// the anchor's Metal buffers, so raw bytes are copied at callback time (Apple sample pattern).
    private var snapshots: [UUID: MeshSnapshot] = [:]
    private var meshNodes: [UUID: SCNNode] = [:]
    private var frameCounter = 0

    /// CPU-owned copy of one ARMeshAnchor's geometry.
    struct MeshSnapshot {
        let vertexData: Data
        let vertexStride: Int
        let indexData: Data
        let bytesPerIndex: Int
        let faceCount: Int

        init?(from mesh: ARMeshAnchor) {
            let geometry = mesh.geometry
            let vertices = geometry.vertices
            let faces = geometry.faces
            // iOS 26 SDK renamed `primitiveCount` to `count` on ARGeometryElement.
            let faceTotal = faces.count
            guard vertices.count > 0, faceTotal > 0 else { return nil }
            vertexData = Data(bytes: vertices.buffer.contents(), count: vertices.buffer.length)
            vertexStride = vertices.stride
            indexData = Data(bytes: faces.buffer.contents(), count: faces.buffer.length)
            bytesPerIndex = faces.bytesPerIndex
            faceCount = faceTotal
        }

        var vertexCount: Int { vertexStride > 0 ? vertexData.count / vertexStride : 0 }
    }

    override init() {
        super.init()
        scene.rootNode.name = "spatialMeshScene"
    }

    // MARK: - Session lifecycle

    func run() {
        guard Self.isSupported else { return }
        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .mesh
        configuration.environmentTexturing = .none
        configuration.frameSemantics = [.sceneDepth]
        arAvailable = true
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        session.pause()
    }

    func stopAndClear() {
        guard Self.isSupported else { return }
        pause()
        lock.lock()
        snapshots.removeAll()
        let nodes = Array(meshNodes.values)
        meshNodes.removeAll()
        lastSnapshot = nil
        lock.unlock()
        DispatchQueue.main.async {
            nodes.forEach { $0.removeFromParentNode() }
            self.anchorCount = 0
            self.triangleCount = 0
            self.probe = nil
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let depth = frame.sceneDepth else { return }
        frameCounter += 1
        // Probe at ~20 Hz; publishing every AR frame is wasteful.
        guard frameCounter % 3 == 0 else { return }
        let upright = frame.displayTransform(for: .portrait, viewportSize: CGSize(width: 1, height: 1))
        let result = LiDARRanging.probeAR(
            depthMap: depth.depthMap,
            imageSize: frame.camera.imageResolution,
            intrinsics: frame.camera.intrinsics,
            upright: upright
        )
        // Store probe and camera pose from the same frame so a pin converts to world
        // coordinates without mixing frames.
        let snapshot = result.map { probe in
            CrosshairSnapshot(probe: probe, camera: frame.camera.transform)
        }
        lock.lock()
        lastSnapshot = snapshot
        lock.unlock()
        DispatchQueue.main.async { self.probe = result }
    }

    /// Probe + camera pose captured from one ARFrame.
    struct CrosshairSnapshot {
        let probe: LiDARProbe
        let camera: simd_float4x4
    }

    private var lastSnapshot: CrosshairSnapshot?

    /// World-space position of the crosshair hit from the latest frame; nil before tracking starts.
    /// ARKit's camera looks along -Z with X right / Y up, matching the probe's axes, so the
    /// camera-space point (x, y, -z) transforms straight into world space.
    func crosshairWorldPosition() -> simd_float3? {
        lock.lock()
        let snapshot = lastSnapshot
        lock.unlock()
        guard let snapshot else { return nil }
        let local = simd_float4(Float(snapshot.probe.x), Float(snapshot.probe.y), Float(-snapshot.probe.z), 1)
        let world = snapshot.camera * local
        return simd_float3(world.x, world.y, world.z)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.arAvailable = false }
        print("ARSession error: \(error.localizedDescription)")
    }

    // MARK: - ARSCNViewDelegate (render thread)

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let mesh = anchor as? ARMeshAnchor else { return }
        lock.lock()
        let snapshot = MeshSnapshot(from: mesh) ?? snapshots[anchor.identifier]
        if let snapshot { snapshots[anchor.identifier] = snapshot }
        meshNodes[anchor.identifier] = node
        let counts = (anchors: snapshots.count, triangles: snapshots.values.reduce(0) { $0 + $1.faceCount })
        lock.unlock()
        node.geometry = snapshot.flatMap { Self.lineGeometry(from: $0, keepRatio: visibleKeepRatio) }
        node.isHidden = !meshVisible
        publishCounts(anchors: counts.anchors, triangles: counts.triangles)
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let mesh = anchor as? ARMeshAnchor else { return }
        lock.lock()
        let snapshot = MeshSnapshot(from: mesh)
        if let snapshot { snapshots[anchor.identifier] = snapshot }
        let triangles = snapshots.values.reduce(0) { $0 + $1.faceCount }
        lock.unlock()
        if let snapshot {
            node.geometry = Self.lineGeometry(from: snapshot, keepRatio: visibleKeepRatio)
        }
        publishCounts(anchors: nil, triangles: triangles)
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard anchor is ARMeshAnchor else { return }
        lock.lock()
        snapshots.removeValue(forKey: anchor.identifier)
        meshNodes.removeValue(forKey: anchor.identifier)
        let anchors = snapshots.count
        let triangles = snapshots.values.reduce(0) { $0 + $1.faceCount }
        lock.unlock()
        publishCounts(anchors: anchors, triangles: triangles)
    }

    /// Current density as a face-keep ratio, safe to read from the render thread.
    private var visibleKeepRatio: Float { Float(meshDensity) / 100 }

    // MARK: - Density / visibility

    private func applyVisibility() {
        lock.lock()
        let nodes = Array(meshNodes.values)
        lock.unlock()
        let visible = meshVisible
        DispatchQueue.main.async { nodes.forEach { $0.isHidden = !visible } }
    }

    /// Rebuilds every node's geometry after the density slider moves.
    private func rebuildAllGeometry() {
        lock.lock()
        let entries = snapshots.mapValues { $0 }
        let nodes = meshNodes
        lock.unlock()
        let ratio = visibleKeepRatio
        DispatchQueue.main.async {
            for (id, snapshot) in entries {
                nodes[id]?.geometry = Self.lineGeometry(from: snapshot, keepRatio: ratio)
            }
        }
    }

    private func publishCounts(anchors: Int?, triangles: Int) {
        DispatchQueue.main.async {
            if let anchors { self.anchorCount = anchors }
            self.triangleCount = triangles
        }
    }

    // MARK: - Wireframe geometry

    /// Turns one mesh snapshot's triangles into white line segments. Edges are de-duplicated so
    /// shared triangle borders draw once; `keepRatio` keeps only every Nth face's edges.
    static func lineGeometry(from snapshot: MeshSnapshot, keepRatio: Float) -> SCNGeometry? {
        let vertexCount = snapshot.vertexCount
        let faceCount = snapshot.faceCount
        guard vertexCount > 0, faceCount > 0 else { return nil }

        let source = SCNGeometrySource(
            data: snapshot.vertexData,
            semantic: .vertex,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: snapshot.vertexStride
        )

        let bytesPerIndex = snapshot.bytesPerIndex
        let faceStride = bytesPerIndex * 3

        // Subsample faces by modulo so "70%" keeps 7 of every 10 faces, spread uniformly.
        let keepOutOfTen = max(1, min(10, Int((keepRatio * 10).rounded())))
        var seen = Set<UInt64>()
        seen.reserveCapacity(faceCount * 3 * keepOutOfTen / 10)
        var lines = [Int32]()
        lines.reserveCapacity(faceCount * 3 * keepOutOfTen / 10)

        snapshot.indexData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let indexBase = raw.baseAddress!
            func vertexIndex(_ face: Int, _ corner: Int) -> Int {
                let offset = face * faceStride + corner * bytesPerIndex
                return bytesPerIndex == 4
                    ? Int(indexBase.load(fromByteOffset: offset, as: UInt32.self))
                    : Int(indexBase.load(fromByteOffset: offset, as: UInt16.self))
            }

            for face in 0..<faceCount {
                if face % 10 >= keepOutOfTen { continue }
                let a = vertexIndex(face, 0), b = vertexIndex(face, 1), c = vertexIndex(face, 2)
                guard a < vertexCount, b < vertexCount, c < vertexCount else { continue }
                for (i, j) in [(a, b), (b, c), (c, a)] {
                    let key = i < j ? UInt64(i) << 32 | UInt64(j) : UInt64(j) << 32 | UInt64(i)
                    if seen.insert(key).inserted {
                        lines.append(Int32(i))
                        lines.append(Int32(j))
                    }
                }
            }
        }
        guard !lines.isEmpty else { return nil }

        let lineCount = lines.count
        let element = SCNGeometryElement(
            data: Data(bytes: lines, count: lineCount * MemoryLayout<Int32>.stride),
            primitiveType: .line,
            primitiveCount: lineCount / 2,
            bytesPerIndex: MemoryLayout<Int32>.stride
        )
        let wire = SCNGeometry(sources: [source], elements: [element])
        wire.firstMaterial = Self.wireMaterial
        return wire
    }

    /// Shared constant white material for every wireframe node.
    private static let wireMaterial: SCNMaterial = {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.isDoubleSided = true
        return material
    }()
}

/// SwiftUI wrapper for the ARKit camera preview + wireframe scene.
struct ARMeshView: UIViewRepresentable {
    let controller: ARMeshController

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = controller.session
        view.delegate = controller
        view.scene = controller.scene
        view.automaticallyUpdatesLighting = false
        view.antialiasingMode = .none
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
