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

    var body: some View {
        VStack {
            Model3D(named: "Scene", bundle: realityKitContentBundle)
                .padding(.bottom, 50)

            Text("Hello, world!")

            ToggleImmersiveSpaceButton()
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
