//
//  ContentView.swift
//  ShiibaVisionOsVisualizer
//
//  Created by 堀宏行 on 2026/02/17.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct ContentView: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        VStack(spacing: 20) {
            Model3D(named: "Scene", bundle: realityKitContentBundle)
                .padding(.bottom, 50)

            Text("Hello, world!")

            // Start button - Display point cloud at saved anchor
            Button {
                Task {
                    if appModel.immersiveSpaceState == .open {
                        // Already open, just ensure we're in point cloud mode
                        appModel.enterPointCloudMode()
                    } else {
                        // Open immersive space and show point cloud
                        appModel.enterPointCloudMode()
                        await openImmersiveSpace(id: appModel.immersiveSpaceID)
                    }
                }
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .disabled(appModel.worldAnchorID == nil && !appModel.isRunningOnSimulator)
            
            Divider()
                .padding(.horizontal)
            
            // World Anchor Placement button
            VStack(spacing: 12) {
                Text("World Anchor Placement")
                    .font(.headline)
                
                // Simulator warning
                if appModel.isRunningOnSimulator {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("シミュレーターでは使用不可")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                if let anchorID = appModel.worldAnchorID {
                    Text("Anchor ID: \(anchorID.uuidString.prefix(8))...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                // Placement preview info (only visible in axes placement mode)
                if appModel.displayMode == .axesPlacement {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("移動して配置位置を決めてください")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        
                        Divider()
                        
                        // Device position
                        if let devicePos = appModel.devicePosition {
                            HStack {
                                Image(systemName: "location.fill")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("現在位置")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("X: \(String(format: "%.2f", devicePos.x))m  Y: \(String(format: "%.2f", devicePos.y))m  Z: \(String(format: "%.2f", devicePos.z))m")
                                        .font(.caption)
                                        .monospaced()
                                }
                            }
                        }
                        
                        // Preview position
                        if let previewPos = appModel.previewPosition {
                            HStack {
                                Image(systemName: "scope")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("配置位置")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text("X: \(String(format: "%.2f", previewPos.x))m  Y: \(String(format: "%.2f", previewPos.y))m  Z: \(String(format: "%.2f", previewPos.z))m")
                                        .font(.caption)
                                        .monospaced()
                                }
                            }
                            
                            // Distance from device
                            if let devicePos = appModel.devicePosition {
                                let distance = length(previewPos - devicePos)
                                HStack {
                                    Image(systemName: "ruler")
                                        .foregroundStyle(.orange)
                                    Text("距離: \(String(format: "%.2f", distance))m")
                                        .font(.caption)
                                }
                            }
                        }
                        
                        // Floor detection status
                        if let floorY = appModel.detectedFloorY {
                            HStack {
                                Image(systemName: "arrow.down.to.line")
                                    .foregroundStyle(.purple)
                                Text("床面検出: Y = \(String(format: "%.2f", floorY))m")
                                    .font(.caption)
                            }
                        } else {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.yellow)
                                Text("床面を検出中...")
                                    .font(.caption)
                            }
                        }
                        
                        Divider()
                        
                        // Confirm placement button
                        Button {
                            Task {
                                await appModel.confirmPlacementAtCurrentPosition()
                                // Close immersive space and return to window
                                await dismissImmersiveSpace()
                                print("[ContentView] ✅ Returned to window - Start button is now enabled")
                            }
                        } label: {
                            Label("ここに決定", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(appModel.previewPosition == nil)
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                
                Button {
                    Task {
                        if appModel.immersiveSpaceState == .open {
                            // Already in immersive space
                            if appModel.displayMode == .axesPlacement {
                                // Already in placement mode - do nothing (use "ここに決定" button above)
                                return
                            } else {
                                // Enter axes placement mode
                                await appModel.enterAxesPlacementMode()
                            }
                        } else {
                            // Open immersive space in placement mode
                            await appModel.enterAxesPlacementMode()
                            await openImmersiveSpace(id: appModel.immersiveSpaceID)
                        }
                    }
                } label: {
                    Label(appModel.worldAnchorID == nil ? "アンカー位置を設定" : "アンカー位置を更新",
                          systemImage: "location.circle")
                }
                .disabled(appModel.displayMode == .axesPlacement || appModel.isRunningOnSimulator)  // Disable on simulator
                
                if appModel.worldAnchorID != nil {
                    Button(role: .destructive) {
                        appModel.worldAnchorManager.clearAnchor()
                    } label: {
                        Label("アンカーをクリア", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(appModel.isRunningOnSimulator)  // Disable on simulator
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding()
        .onAppear {
            checkiCloudFiles()
            prefetchAllFiles()
        }
        .onChange(of: appModel.immersiveSpaceState) { _, newState in
            // Dismiss window when starting point cloud display (not in axes placement mode)
            if newState == .open && appModel.displayMode == .pointCloud {
                dismissWindow()
            }
        }
    }
}

private func prefetchAllFiles() {
    let containerID = "iCloud.jp.p4n.ShiibaVisionOsVisualizer"
    guard let iCloudBase = FileManager.default.url(
        forUbiquityContainerIdentifier: containerID
    )?.appendingPathComponent("Documents/Shimonju") else {
        print("[iCloud prefetch] ❌ container not found")
        return
    }

    guard let files = try? FileManager.default.contentsOfDirectory(
        at: iCloudBase,
        includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey]
    ) else {
        print("[iCloud prefetch] ❌ cannot list files")
        return
    }

    var requested = 0
    for file in files {
        let status = try? file.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if status?.ubiquitousItemDownloadingStatus != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: file)
            requested += 1
        }
    }
    print("[iCloud prefetch] ✅ download requested: \(requested) files")
}

private func checkiCloudFiles() {
    let containerID = "iCloud.jp.p4n.ShiibaVisionOsVisualizer"
    guard let iCloudURL = FileManager.default.url(
        forUbiquityContainerIdentifier: containerID
    )?.appendingPathComponent("Documents/Shimonju") else {
        print("[iCloud] ❌ container not found: \(containerID)")
        return
    }
    print("[iCloud] container URL: \(iCloudURL.path)")
    do {
        let files = try FileManager.default.contentsOfDirectory(atPath: iCloudURL.path)
        print("[iCloud] ✅ files count: \(files.count)")
        files.prefix(5).forEach { print("[iCloud]   \($0)") }
    } catch {
        print("[iCloud] ❌ error: \(error)")
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
