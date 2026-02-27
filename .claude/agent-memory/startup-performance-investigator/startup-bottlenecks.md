# Startup Bottlenecks Detail (2026-02-26)

## Critical
1. AppModel.init() calls arSession.run() via Task { await startARSession() }
   - arSession = ARKitSession(), worldTracking = WorldTrackingProvider(), planeDetection = PlaneDetectionProvider()
   - All three allocated eagerly as `let` properties at declaration (before init body)
   - ARSession.run([worldTracking, planeDetection]) is async but fires immediately on init

2. ContentView.onAppear -> checkiCloudFiles() + prefetchAllFiles()
   - Both call FileManager.default.url(forUbiquityContainerIdentifier:) synchronously on main thread
   - forUbiquityContainerIdentifier can block 100-500ms on cold start
   - prefetchAllFiles also calls contentsOfDirectory + resourceValues per file on main thread

## High
3. Model3D(named: "Scene") in ContentView body
   - Loads RealityKit .rkassets bundle synchronously on first render
   - GridMaterial shader compilation included
   - Blocks first meaningful paint of the window

4. WorldAnchorManager.startMonitoring() in AppModel.init()
   - Starts a Task to monitor anchorUpdates immediately
   - Monitoring runs before ARSession is confirmed running
   - Minor: does not block but creates orphan tasks

## Medium
5. PointCloudRenderer.init() and AxesRenderer.init() inside Renderer.init()
   - device.makeDefaultLibrary() called TWICE (once in each renderer)
   - Each compiles/loads the same .metallib - should be shared
   - Happens on RendererTaskExecutor thread (not main), but still redundant work

6. Renderer.scanICloudPLYFiles() inside scanAndStartAnimation()
   - Called from Renderer.startRenderLoop() Task after ImmersiveSpace opens
   - forUbiquityContainerIdentifier called AGAIN (third time total if iCloud available)
   - contentsOfDirectory on iCloud path can stall if files not yet downloaded

7. AVPlayer(url:) initialisation in startAudio()
   - Created synchronously on RendererTaskExecutor thread
   - Audio file search via contentsOfDirectory on iCloud (fourth iCloud access)

## Low
8. Multiple iCloud container lookups (total 4 separate calls across startup)
   - ContentView.checkiCloudFiles: 1 call
   - ContentView.prefetchAllFiles: 1 call
   - Renderer.scanICloudPLYFiles: 1 call
   - Renderer.scanAudioFile: 1 call
   - Each call to forUbiquityContainerIdentifier has overhead; result is never cached

9. Throttled debug prints using Int.random(in: 0..<240) every frame
   - Random number generation per frame is minor but non-zero overhead during rendering

## Not a Problem (correctly implemented)
- PLYLoader uses Data(contentsOf: options: .mappedIfSafe) - mmap, not full read
- PLYLoader is an actor - serial access, no data races
- Animation frames loaded with Task.detached(priority: .userInitiated) - off main thread
- sharedRenderState uses OSAllocatedUnfairLock - fast lock-free-like synchronisation
- ARKit session shared between AppModel and Renderer (no duplicate session)
