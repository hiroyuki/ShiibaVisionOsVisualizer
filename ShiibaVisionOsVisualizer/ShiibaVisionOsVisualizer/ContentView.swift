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

    var body: some View {
        VStack(spacing: 20) {
            Model3D(named: "Scene", bundle: realityKitContentBundle)
                .padding(.bottom, 50)

            Text("Hello, world!")

            // 既存のトグルボタン
            ToggleImmersiveSpaceButton()
            
            Divider()
                .padding(.horizontal)
            
            // Point Cloud配置モードボタン
            VStack(spacing: 12) {
                Text("Point Cloud Placement")
                    .font(.headline)
                
                if let anchorID = appModel.worldAnchorID {
                    Text("Anchor ID: \(anchorID.uuidString.prefix(8))...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Button {
                    Task {
                        if appModel.immersiveSpaceState == .open {
                            // Already in immersive space
                            if appModel.isInPlacementMode {
                                // Confirm placement and save WorldAnchor
                                await appModel.confirmPlacement()
                            } else {
                                // Enter placement mode
                                appModel.startPlacementMode()
                            }
                        } else {
                            // Open immersive space in placement mode
                            appModel.startPlacementMode()
                            await openImmersiveSpace(id: appModel.immersiveSpaceID)
                        }
                    }
                } label: {
                    if appModel.isInPlacementMode {
                        Label("Confirm Placement", systemImage: "checkmark.circle")
                    } else {
                        Label(appModel.worldAnchorID == nil ? "Set Anchor Position" : "Update Anchor Position",
                              systemImage: "location.circle")
                    }
                }
                
                if appModel.worldAnchorID != nil {
                    Button(role: .destructive) {
                        appModel.clearAnchor()
                    } label: {
                        Label("Clear Anchor", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding()
        .onAppear {
//            #if DEBUG
//            checkiCloudFiles()
//            prefetchAllFiles()
//            #endif
        }
        .onChange(of: appModel.immersiveSpaceState) { _, newState in
            if newState == .open {
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
