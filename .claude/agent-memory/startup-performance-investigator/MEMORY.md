# Startup Performance Investigator - Project Memory

## Project: ShiibaVisionOsVisualizer
- Platform: visionOS (Apple Vision Pro)
- Stack: Swift/SwiftUI + Metal + ARKit + CompositorServices + iCloud Drive
- Entry point: `ShiibaVisionOsVisualizerApp.swift` (@main)

## Key File Paths
- App entry: `ShiibaVisionOsVisualizer/ShiibaVisionOsVisualizerApp.swift`
- AppModel: `ShiibaVisionOsVisualizer/AppModel.swift` (@MainActor @Observable)
- ContentView: `ShiibaVisionOsVisualizer/ContentView.swift`
- Renderer: `ShiibaVisionOsVisualizer/Renderer.swift` (actor)
- PointCloudRenderer: `ShiibaVisionOsVisualizer/Renderer/PointCloudRenderer.swift`
- PLYLoader: `ShiibaVisionOsVisualizer/Data/PLYLoader.swift` (actor)
- WorldAnchorManager: `ShiibaVisionOsVisualizer/WorldAnchorManager.swift` (@MainActor)

## Confirmed Startup Bottlenecks (2026-02-26 investigation)
See: startup-bottlenecks.md

## Architecture Notes
- ARKit session started eagerly in AppModel.init() on non-simulator
- WorldAnchorManager.startMonitoring() called in AppModel.init()
- iCloud container access happens in ContentView.onAppear (checkiCloudFiles + prefetchAllFiles)
- PLY loading is deferred until ImmersiveSpace opens and Renderer initialises
- Model3D("Scene") loaded synchronously in ContentView body - RealityKit asset load on appear
- `forUbiquityContainerIdentifier` is a blocking call (~100-500ms on first access)
- PLYLoader uses .mappedIfSafe for disk reads (good - zero-copy mmap)
- Animation frames loaded at 30fps with Task.detached (good - off main thread)
