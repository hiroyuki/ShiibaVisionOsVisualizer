//
//  AppModel.swift
//  ShiibaVisionOsVisualizer
//
//  Created by 堀宏行 on 2026/02/17.
//

import SwiftUI
import ARKit

/// Maintains app-wide state
@MainActor
@Observable
class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    
    enum ImmersiveSpaceState {
        case closed
        case inTransition
        case open
    }
    var immersiveSpaceState = ImmersiveSpaceState.closed
    
    // Display mode
    enum DisplayMode {
        case pointCloud      // Display point cloud at saved anchor
        case axesPlacement   // Display axes at user's current position for anchor placement
    }
    var displayMode: DisplayMode = .pointCloud
    
    // Shared ARKit session and providers
    let arSession = ARKitSession()
    let worldTracking = WorldTrackingProvider()
    let planeDetection = PlaneDetectionProvider(alignments: [.horizontal])
    private var isARSessionRunning = false
    
    // Point cloud placement
    var worldAnchorID: UUID?
    var worldAnchor: WorldAnchor?
    
    // Device position tracking (updated every frame from Renderer)
    var devicePosition: SIMD3<Float>?
    var deviceTransform: matrix_float4x4?  // Full transform including orientation
    var previewPosition: SIMD3<Float>?  // Calculated preview position for axes
    
    // Floor detection
    var detectedFloorY: Float?  // Y coordinate of detected floor
    
    // Preview offset from device (default: 1.0m forward, at eye level)
    var previewOffsetFromDevice: SIMD3<Float> = SIMD3<Float>(0, 0, -1.0)
    
    init() {
        // Load saved world anchor ID
        loadWorldAnchorID()
        
        // Start ARKit session
        Task {
            await startARSession()
        }
    }
    
    private func startARSession() async {
        guard !isARSessionRunning else { return }
        
        do {
            try await arSession.run([worldTracking, planeDetection])
            isARSessionRunning = true
            print("[AppModel] ARKit session started with world tracking and plane detection")
        } catch {
            print("[AppModel] Failed to start ARKit session: \(error)")
        }
    }
    
    func saveWorldAnchorID(_ id: UUID) {
        worldAnchorID = id
        UserDefaults.standard.set(id.uuidString, forKey: "pointCloudWorldAnchorID")
        UserDefaults.standard.synchronize()  // Force immediate save
        print("[AppModel] Saved world anchor ID: \(id)")
    }
    
    func loadWorldAnchorID() {
        if let uuidString = UserDefaults.standard.string(forKey: "pointCloudWorldAnchorID"),
           let uuid = UUID(uuidString: uuidString) {
            worldAnchorID = uuid
            print("[AppModel] Loaded world anchor ID: \(uuid)")
        } else {
            print("[AppModel] No saved world anchor ID found in UserDefaults")
        }
    }
    
    func updateWorldAnchor(_ anchor: WorldAnchor) {
        worldAnchor = anchor
        print("[AppModel] Updated world anchor: \(anchor.id)")
    }
    
    func clearAnchor() {
        worldAnchorID = nil
        worldAnchor = nil
        UserDefaults.standard.removeObject(forKey: "pointCloudWorldAnchorID")
        print("[AppModel] Cleared anchor")
    }
    
    func enterAxesPlacementMode() async {
        displayMode = .axesPlacement
        devicePosition = nil
        deviceTransform = nil
        previewPosition = nil
        
        // Remove all existing world anchors before starting placement mode
        await removeAllWorldAnchors()
        
        print("[AppModel] Entered axes placement mode - waiting for user to move to desired position")
    }
    
    func enterPointCloudMode() {
        displayMode = .pointCloud
        print("[AppModel] Entered point cloud mode")
    }
    
    func updateDeviceTransform(_ transform: matrix_float4x4) {
        deviceTransform = transform
        
        // Extract device position
        let position = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        devicePosition = position
        
        // Calculate preview position with device orientation
        // Get forward direction from device transform (negative Z axis in camera space)
        let forward = SIMD3<Float>(
            -transform.columns.2.x,
            -transform.columns.2.y,
            -transform.columns.2.z
        )
        
        // Calculate preview position: device position + offset in device's forward direction
        let forwardOffset = forward * abs(previewOffsetFromDevice.z)  // 1.0m forward
        var preview = position + forwardOffset
        
        // If floor is detected, place on floor. Otherwise, place 1m below eye level
        if let floorY = detectedFloorY {
            preview.y = floorY
        } else {
            preview.y = position.y - 1.0  // 1m below device (eye level)
        }
        
        previewPosition = preview
        
        // Debug log (throttled)
        if Int.random(in: 0..<240) == 0 {
            print("[AppModel] Device: \(position), Forward: \(forward), Preview: \(preview), Floor: \(detectedFloorY?.description ?? "nil")")
        }
    }
    
    func updateDetectedFloor(_ floorY: Float) {
        self.detectedFloorY = floorY
        print("[AppModel] Floor detected at Y: \(floorY)")
    }
    
    func removeAllWorldAnchors() async {
        print("[AppModel] 🗑️ Removing all existing WorldAnchors...")
        
        // Wait for ARKit session to be fully running
        if !isARSessionRunning {
            print("[AppModel] ⚠️ ARKit session not running yet, waiting...")
            // Wait a bit for session to start
            try? await Task.sleep(for: .milliseconds(500))
            
            // Check again
            if !isARSessionRunning {
                print("[AppModel] ⚠️ ARKit session still not running, skipping anchor removal")
                return
            }
        }
        
        // Wait for world tracking provider to be ready
        // Query device anchor to ensure provider is running
        var retryCount = 0
        let maxRetries = 10
        
        while retryCount < maxRetries {
            if worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) != nil {
                // Provider is ready
                print("[AppModel] ✅ World tracking provider is ready")
                break
            }
            
            print("[AppModel] ⏳ Waiting for world tracking provider... (\(retryCount + 1)/\(maxRetries))")
            try? await Task.sleep(for: .milliseconds(200))
            retryCount += 1
        }
        
        if retryCount >= maxRetries {
            print("[AppModel] ⚠️ World tracking provider not ready after \(maxRetries) retries, skipping anchor removal")
            return
        }
        
        // Get all anchors from worldTracking
        guard let allAnchors = await worldTracking.allAnchors else {
            print("[AppModel] ℹ️ No anchors to remove")
            return
        }
        
        print("[AppModel] 📋 Found \(allAnchors.count) total anchor(s)")
        
        var removedCount = 0
        for anchor in allAnchors {
            if let worldAnchor = anchor as? WorldAnchor {
                do {
                    try await worldTracking.removeAnchor(worldAnchor)
                    removedCount += 1
                    print("[AppModel] 🗑️ Removed WorldAnchor: \(worldAnchor.id)")
                } catch {
                    print("[AppModel] ⚠️ Failed to remove WorldAnchor \(worldAnchor.id): \(error)")
                }
            }
        }
        
        // Clear cached state
        worldAnchorID = nil
        worldAnchor = nil
        UserDefaults.standard.removeObject(forKey: "pointCloudWorldAnchorID")
        UserDefaults.standard.synchronize()
        
        print("[AppModel] ✅ Removed \(removedCount) WorldAnchor(s)")
    }
    
    func confirmPlacementAtCurrentPosition() async {
        guard let finalPosition = previewPosition else {
            print("[AppModel] ❌ Preview position not available")
            return
        }
        
        // Create WorldAnchor at preview position
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(finalPosition.x, finalPosition.y, finalPosition.z, 1.0)
        
        let worldAnchor = WorldAnchor(originFromAnchorTransform: transform)
        
        do {
            try await worldTracking.addAnchor(worldAnchor)
            saveWorldAnchorID(worldAnchor.id)
            updateWorldAnchor(worldAnchor)  // This sets self.worldAnchor immediately
            print("[AppModel] ✅ WorldAnchor created and saved: \(worldAnchor.id)")
            print("[AppModel] ✅ Placement confirmed at position: \(finalPosition)")
            
            // Verify the anchor was added successfully by checking allAnchors
            try? await Task.sleep(for: .milliseconds(500))
            if let allAnchors = await worldTracking.allAnchors {
                let anchorExists = allAnchors.contains { anchor in
                    guard let wa = anchor as? WorldAnchor else { return false }
                    return wa.id == worldAnchor.id
                }
                
                if anchorExists {
                    print("[AppModel] ✅ Verified: New anchor is being tracked by ARKit")
                } else {
                    print("[AppModel] ⚠️ Warning: New anchor not found in ARKit's tracked anchors")
                }
            }
            
            // Don't enter point cloud mode - return to window instead
            // Point cloud mode will be entered when user presses "Start"
            print("[AppModel] 💡 Ready to close immersive space and return to window")
        } catch {
            print("[AppModel] ❌ Failed to save WorldAnchor: \(error)")
        }
    }
}

