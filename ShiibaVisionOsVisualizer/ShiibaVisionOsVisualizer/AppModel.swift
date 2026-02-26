//
//  AppModel.swift
//  ShiibaVisionOsVisualizer
//
//  Created by 堀宏行 on 2026/02/17.
//

import SwiftUI
import ARKit
import os

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
    
    // Simulator detection
    var isRunningOnSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
    
    // Shared ARKit session and providers
    let arSession = ARKitSession()
    let worldTracking = WorldTrackingProvider()
    let planeDetection = PlaneDetectionProvider(alignments: [.horizontal])
    private var isARSessionRunning = false
    
    // Simulator mode: fake anchor at 1m forward, floor level
    var simulatorFakeAnchorTransform: matrix_float4x4 {
        matrix4x4_translation(0, 0, -1.0)
    }
    
    // WorldAnchor management
    let worldAnchorManager: WorldAnchorManager
    
    // Computed properties for backward compatibility (ContentView等)
    var worldAnchorID: UUID? { worldAnchorManager.anchorID }
    var worldAnchor: WorldAnchor? { worldAnchorManager.anchor }
    
    // Device position tracking (updated every frame from Renderer)
    var devicePosition: SIMD3<Float>?
    var deviceTransform: matrix_float4x4?  // Full transform including orientation
    var previewPosition: SIMD3<Float>?  // Calculated preview position for axes
    
    // Floor detection
    var detectedFloorY: Float?  // Y coordinate of detected floor
    
    // Preview offset from device (default: 1.0m forward, at eye level)
    var previewOffsetFromDevice: SIMD3<Float> = SIMD3<Float>(0, 0, -1.0)
    
    init() {
        worldAnchorManager = WorldAnchorManager(worldTracking: worldTracking)
        worldAnchorManager.loadSavedAnchorID()
        
        if isRunningOnSimulator {
            print("[AppModel] 🖥️ Running on simulator - ARKit disabled")
            isARSessionRunning = true
            
            if worldAnchorManager.anchorID == nil {
                let fakeID = UUID()
                worldAnchorManager.anchorID = fakeID
                UserDefaults.standard.set(fakeID.uuidString, forKey: "pointCloudWorldAnchorID")
                print("[AppModel] 🖥️ Created fake anchor ID for simulator: \(fakeID)")
            }
        } else {
            worldAnchorManager.startMonitoring()
            Task {
                await startARSession()
            }
        }
    }
    
    private func startARSession() async {
        guard !isARSessionRunning else { return }
        
        // Skip ARKit on simulator
        if isRunningOnSimulator {
            print("[AppModel] 🖥️ Skipping ARKit session on simulator")
            return
        }
        
        do {
            try await arSession.run([worldTracking, planeDetection])
            isARSessionRunning = true
            print("[AppModel] ARKit session started with world tracking and plane detection")
        } catch {
            print("[AppModel] Failed to start ARKit session: \(error)")
        }
    }
    
    func enterAxesPlacementMode() async {
        // Disable axes placement on simulator
        if isRunningOnSimulator {
            print("[AppModel] 🖥️ Axes placement mode not available on simulator")
            return
        }
        
        displayMode = .axesPlacement
        sharedRenderState.withLock { $0.displayMode = .axesPlacement }
        devicePosition = nil
        deviceTransform = nil
        previewPosition = nil
        
        // Remove all existing world anchors before starting placement mode
        await worldAnchorManager.removeAllAnchors()
        worldAnchorManager.clearAnchor()
        
        print("[AppModel] Entered axes placement mode - waiting for user to move to desired position")
    }
    
    func enterPointCloudMode() {
        displayMode = .pointCloud
        sharedRenderState.withLock { $0.displayMode = .pointCloud }
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
        
        // Calculate preview position: directly below device (same X, Z, but at floor level)
        var preview = position
        
        // If floor is detected, place on floor. Otherwise, place 1m below eye level
        if let floorY = detectedFloorY {
            preview.y = floorY
        } else {
            preview.y = position.y - 1.5  // 1.5m below device (approximate floor)
        }
        
        previewPosition = preview
        
        // Debug log (throttled)
        if Int.random(in: 0..<240) == 0 {
            print("[AppModel] Device: \(position), Preview (directly below): \(preview), Floor: \(detectedFloorY?.description ?? "nil")")
        }
    }
    
    func updateDetectedFloor(_ floorY: Float) {
        self.detectedFloorY = floorY
        print("[AppModel] Floor detected at Y: \(floorY)")
    }
    
    
    func confirmPlacementAtCurrentPosition() async {
        // Disable on simulator
        if isRunningOnSimulator {
            print("[AppModel] 🖥️ Anchor placement not available on simulator")
            return
        }
        
        guard let finalPosition = previewPosition else {
            print("[AppModel] ❌ Preview position not available")
            return
        }
        
        guard let deviceTransform = deviceTransform else {
            print("[AppModel] ❌ Device transform not available")
            return
        }
        
        // Calculate yaw angle from device transform
        let forward = SIMD3<Float>(
            -deviceTransform.columns.2.x,
            -deviceTransform.columns.2.y,
            -deviceTransform.columns.2.z
        )
        let forwardXZ = SIMD3<Float>(forward.x, 0, forward.z)
        let normalizedForwardXZ = normalize(forwardXZ)
        let yaw = -atan2(normalizedForwardXZ.x, -normalizedForwardXZ.z)
        
        // Use detected floor Y coordinate if available, otherwise use preview position Y
        let floorY = detectedFloorY ?? finalPosition.y
        
        // Build transform with both translation AND rotation (yaw embedded in anchor)
        let anchorPosition = SIMD3<Float>(finalPosition.x, floorY, finalPosition.z)
        let rotationMatrix = matrix4x4_rotation(radians: yaw, axis: SIMD3<Float>(0, 1, 0))
        let translationMatrix = matrix4x4_translation(anchorPosition.x, anchorPosition.y, anchorPosition.z)
        let transform = translationMatrix * rotationMatrix
        
        await worldAnchorManager.placeAnchor(transform: transform)
        
        print("[AppModel] ✅ Placement confirmed at position: \(anchorPosition) (floor Y: \(floorY), yaw: \(yaw * 180 / .pi)°)")
        print("[AppModel] 💡 Ready to close immersive space and return to window")
    }
}

