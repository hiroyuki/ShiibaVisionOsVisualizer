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
    
    // Placement mode state
    var isInPlacementMode = false
    
    // Shared ARKit session and providers
    let arSession = ARKitSession()
    let worldTracking = WorldTrackingProvider()
    private var isARSessionRunning = false
    
    // Point cloud placement
    var worldAnchorID: UUID?
    var worldAnchor: WorldAnchor?
    var placementPosition: SIMD3<Float> = SIMD3<Float>(0, 0, -1.5) // Default 1.5m in front
    
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
            try await arSession.run([worldTracking])
            isARSessionRunning = true
            print("[AppModel] ARKit session started and running")
        } catch {
            print("[AppModel] Failed to start ARKit session: \(error)")
        }
    }
    
    func saveWorldAnchorID(_ id: UUID) {
        worldAnchorID = id
        UserDefaults.standard.set(id.uuidString, forKey: "pointCloudWorldAnchorID")
        print("[AppModel] Saved world anchor ID: \(id)")
    }
    
    func loadWorldAnchorID() {
        if let uuidString = UserDefaults.standard.string(forKey: "pointCloudWorldAnchorID"),
           let uuid = UUID(uuidString: uuidString) {
            worldAnchorID = uuid
            print("[AppModel] Loaded world anchor ID: \(uuid)")
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
    
    func startPlacementMode() {
        isInPlacementMode = true
        print("[AppModel] Started placement mode")
    }
    
    func finishPlacementMode() {
        isInPlacementMode = false
        print("[AppModel] Finished placement mode")
    }
    
    func confirmPlacement() async {
        // Create WorldAnchor at current placement position
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(placementPosition.x, placementPosition.y, placementPosition.z, 1.0)
        
        let worldAnchor = WorldAnchor(originFromAnchorTransform: transform)
        
        do {
            try await worldTracking.addAnchor(worldAnchor)
            saveWorldAnchorID(worldAnchor.id)
            updateWorldAnchor(worldAnchor)
            finishPlacementMode()
            print("[AppModel] Placement confirmed and WorldAnchor saved: \(worldAnchor.id)")
        } catch {
            print("[AppModel] Failed to save WorldAnchor: \(error)")
        }
    }
}

