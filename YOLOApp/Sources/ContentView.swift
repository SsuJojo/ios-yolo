import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = DetectorViewModel()
    @State private var showBenchmark = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                CameraPreview(session: viewModel.camera.session, rotationAngle: viewModel.videoRotationAngle)
                    .ignoresSafeArea()
                if viewModel.detectionMode == .lidar {
                    LiDAROverlay(gridVisible: viewModel.lidarGridVisible)
                        .ignoresSafeArea()
                } else {
                    DetectionOverlay(detections: viewModel.detections, tags: viewModel.tags, imageSize: viewModel.imageSize)
                        .ignoresSafeArea()
                }

                if usesSidePanel(for: proxy.size) {
                    sidePanelLayout(in: proxy.size)
                } else {
                    compactLayout
                }

                if viewModel.isLoading {
                    ProgressView("正在加载模型…\n首次在 NPU 上加载需要编译，可能需要数秒")
                        .multilineTextAlignment(.center)
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .onAppear { viewModel.start() }
        .sheet(isPresented: $showBenchmark) {
            BenchmarkView(viewModel: viewModel)
        }
    }

    /// iPads get a side panel so the camera keeps a wide, uncropped view in both orientations.
    /// Narrow Split View / Stage Manager windows fall back to the compact bottom panel.
    private func usesSidePanel(for size: CGSize) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular && size.width >= 700
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            statsHUD
            Spacer()
            controlPanel
                .frame(maxWidth: 560)
        }
        .padding(.horizontal, 12)
    }

    private func sidePanelLayout(in size: CGSize) -> some View {
        let panelWidth = min(380, max(300, size.width * 0.34))
        return HStack(alignment: .top, spacing: 16) {
            statsHUD
                .frame(maxWidth: 420, alignment: .leading)
                .padding(.top, 8)
            Spacer(minLength: 0)
            ScrollView {
                controlPanel
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .frame(width: panelWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(16)
    }

    private var statsHUD: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(viewModel.detectionMode == .aprilTag ? "AprilTag" : viewModel.selectedModel?.name ?? "无模型")
                    .font(.headline)
                Text(viewModel.detectionMode == .aprilTag ? "CPU" : viewModel.computeMode.title)
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                Spacer()
                Text(String(format: "%.1f FPS", viewModel.stats.fps))
                    .font(.headline.monospacedDigit())
            }
            if viewModel.detectionMode.runsYOLO {
                HStack(spacing: 12) {
                    metric("推理", String(format: "%.1f ms", viewModel.stats.inferenceMs))
                    metric("后处理", String(format: "%.2f ms", viewModel.stats.postprocessMs))
                    metric("目标", "\(viewModel.stats.objectCount)")
                }
            }
            if viewModel.detectionMode == .lidar {
                Text(viewModel.lidarAvailable ? "LiDAR 深度有效 · 准星实时测距" : "未检测到 LiDAR，需要 iPhone/iPad Pro")
                    .font(.caption)
                    .foregroundColor(viewModel.lidarAvailable ? .mint : .orange)
            }
            if viewModel.detectionMode.runsAprilTag {
                HStack(spacing: 12) {
                    metric("AprilTag", String(format: "%.1f ms", viewModel.stats.tagMs))
                    metric("Tag", "\(viewModel.stats.tagCount)")
                    metric("内参", viewModel.stats.intrinsicsFromCamera ? "相机标定" : "FOV 估算")
                }
            }
            if let error = viewModel.errorMessage {
                Text(error).font(.caption).foregroundColor(.red)
            } else if let status = viewModel.statusMessage {
                Text(status).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.top, 8)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundColor(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.caption)
    }

    private var controlPanel: some View {
        VStack(spacing: 12) {
            Picker("检测模式", selection: $viewModel.detectionMode) {
                ForEach(DetectionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.detectionMode.runsYOLO {
                yoloControls
            }
            if viewModel.detectionMode.runsAprilTag {
                aprilTagControls
            }
            if viewModel.detectionMode == .lidar {
                lidarControls
            }

            if viewModel.detectionMode != .lidar {
                HStack {
                    Menu {
                        ForEach(ModelGroup.groups(of: viewModel.models)) { group in
                            Section(group.title) {
                                ForEach(group.models) { model in
                                    Button {
                                        viewModel.selectedModel = model
                                    } label: {
                                        if model == viewModel.selectedModel {
                                            Label(model.menuTitle, systemImage: "checkmark")
                                        } else {
                                            Text(model.menuTitle)
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(viewModel.selectedModel?.name ?? "选择模型", systemImage: "cube.box")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        showBenchmark = true
                    } label: {
                        Label("跑分对比", systemImage: "speedometer")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .disabled(viewModel.isLoading || viewModel.isBenchmarking)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var yoloControls: some View {
        Picker("计算单元", selection: $viewModel.computeMode) {
            ForEach(ComputeMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        Text(viewModel.computeMode.detail)
            .font(.caption2)
            .foregroundColor(.secondary)

        HStack {
            Text("置信度").font(.caption)
            Slider(value: $viewModel.confidence, in: 0.05...0.95, step: 0.05)
            Text(String(format: "%.2f", viewModel.confidence))
                .font(.caption.monospacedDigit())
                .frame(width: 36)
        }
    }

    @ViewBuilder
    private var aprilTagControls: some View {
        HStack {
            Stepper(value: $viewModel.tagSizeCM, in: 1...100, step: 0.1) {
                Text(String(format: "Tag 边长 %.1f cm", viewModel.tagSizeCM))
                    .font(.caption.monospacedDigit())
            }
            Picker("图案方向", selection: $viewModel.tagOrientation) {
                ForEach(TagPatternOrientation.allCases) { orientation in
                    Text(orientation.title).tag(orientation)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
        }

        HStack {
            Text("平滑").font(.caption)
            Slider(value: $viewModel.tagSmoothing, in: 0...1)
            Text(viewModel.tagSmoothing < 0.34 ? "灵敏" : viewModel.tagSmoothing < 0.67 ? "均衡" : "稳定")
                .font(.caption)
                .frame(width: 36)
        }

        Text("tag36h11 · 原点=Tag 左上角 · X→右 Y→上 Z→垂直指出 Tag · 坐标为相机系 (cm)")
            .font(.caption2)
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private var lidarControls: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let probe = viewModel.lidarProbe {
                Text(String(format: "%.2f m", probe.range))
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(.mint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: "X %+.2f   Y %+.2f", probe.x, probe.y))
                    Text(String(format: "Z %+.2f", probe.z))
                }
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            } else {
                Text("— m")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                Text(viewModel.lidarAvailable ? "准星处无有效深度" : "设备无 LiDAR")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }

        HStack(spacing: 8) {
            Button {
                viewModel.pinLiDARPoint()
            } label: {
                Label("固定取点", systemImage: "mappin")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            .disabled(viewModel.lidarProbe == nil)

            Button {
                viewModel.lidarGridVisible.toggle()
            } label: {
                Text(viewModel.lidarGridVisible ? "网格：开" : "网格：关")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                viewModel.clearPinnedPoints()
            } label: {
                Text("清除点")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.pinnedPoints.isEmpty)
        }

        if !viewModel.pinnedPoints.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(viewModel.pinnedPoints.enumerated()), id: \.element.id) { index, point in
                    let probe = point.probe
                    let span = index == 0 ? "" : String(format: "   距上一点 %.2f m", probe.distance(to: viewModel.pinnedPoints[index - 1].probe))
                    Text(String(format: "#%d  %.2f m   X %+.2f  Y %+.2f  Z %+.2f%@", index + 1, probe.range, probe.x, probe.y, probe.z, span))
                        .font(.caption2.monospacedDigit())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Text("单位：米 · 坐标原点为镜头中心 · X→右 Y→上 Z→镜头正前方 · 取点坐标相对取点时刻的相机位置，设备移动后不跟随")
            .font(.caption2)
            .foregroundColor(.secondary)
    }
}
