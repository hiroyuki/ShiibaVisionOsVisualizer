//
//  WorldAnchorManager.swift
//  ShiibaVisionOsVisualizer
//
//  Created by 堀宏行 on 2026/02/26.
//

import ARKit
import os
import simd

/// WorldAnchor の監視・復元・配置を一元管理する。
/// AppModel の生存期間と同じライフタイムを持ち、
/// Renderer の生成・破棄に影響されない。
@MainActor
@Observable
class WorldAnchorManager {

    // MARK: - Public State

    /// UserDefaults に保存されたアンカー ID
    var anchorID: UUID?

    /// ARKit から復元/作成されたアンカー
    var anchor: WorldAnchor?

    /// Renderer が読む行列（isTracked == true の時のみセット）
    var anchorTransform: matrix_float4x4?

    // MARK: - Dependencies

    private let worldTracking: WorldTrackingProvider
    private var monitorTask: Task<Void, Never>?

    // MARK: - Init

    init(worldTracking: WorldTrackingProvider) {
        self.worldTracking = worldTracking
    }

    // MARK: - Public API

    /// UserDefaults からアンカー ID を読み込む
    func loadSavedAnchorID() {
        if let uuidString = UserDefaults.standard.string(forKey: "pointCloudWorldAnchorID"),
           let uuid = UUID(uuidString: uuidString) {
            anchorID = uuid
            print("[ANCHOR-TRACE] 3️⃣ UUID LOADED from UserDefaults. UUID: \(uuid)")
        } else {
            print("[ANCHOR-TRACE] 3️⃣ No UUID found in UserDefaults")
        }
    }

    /// 新規アンカーを作成・永続化する
    func placeAnchor(transform: matrix_float4x4) async {
        let worldAnchor = WorldAnchor(originFromAnchorTransform: transform)

        do {
            try await worldTracking.addAnchor(worldAnchor)
            print("[ANCHOR-TRACE] 1️⃣ WorldAnchor PERSISTED via addAnchor. UUID: \(worldAnchor.id)")
            saveAnchorID(worldAnchor.id)
            self.anchor = worldAnchor
            setAnchorTransform(transform)
            print("[WorldAnchorManager] ✅ WorldAnchor created and saved: \(worldAnchor.id)")
        } catch {
            print("[WorldAnchorManager] ❌ Failed to save WorldAnchor: \(error)")
        }
    }

    /// ARKit から全アンカーを削除する（provider が running の状態で呼ぶこと）
    func removeAllAnchors() async {
        print("[WorldAnchorManager] 🗑️ Removing all existing WorldAnchors...")
        do {
            try await worldTracking.removeAllAnchors()
            print("[WorldAnchorManager] ✅ removeAllAnchors() succeeded")
        } catch {
            print("[WorldAnchorManager] ⚠️ removeAllAnchors() failed: \(error)")
        }
    }

    /// anchorUpdates 監視を開始する（重複呼び出しは無視）
    func startMonitoring() {
        guard monitorTask == nil else {
            print("[WorldAnchorManager] ℹ️ Already monitoring")
            return
        }
        monitorTask = Task {
            await monitorAnchorUpdates()
        }
        print("[WorldAnchorManager] ▶️ Monitoring started")
    }

    /// 監視を停止する
    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        print("[WorldAnchorManager] ⏹ Monitoring stopped")
    }

    /// アンカーをクリアする（UserDefaults も含む）
    func clearAnchor() {
        anchorID = nil
        anchor = nil
        setAnchorTransform(nil)
        UserDefaults.standard.removeObject(forKey: "pointCloudWorldAnchorID")
        print("[WorldAnchorManager] Cleared anchor")
    }

    // MARK: - Internal

    private func saveAnchorID(_ id: UUID) {
        anchorID = id
        UserDefaults.standard.set(id.uuidString, forKey: "pointCloudWorldAnchorID")
        print("[ANCHOR-TRACE] 2️⃣ UUID SAVED to UserDefaults. UUID: \(id)")
    }

    private func monitorAnchorUpdates() async {
        print("[WorldAnchorManager] Monitoring anchorUpdates...")

        for await update in worldTracking.anchorUpdates {
            guard !Task.isCancelled else { break }
            guard let worldAnchor = update.anchor as? WorldAnchor else { continue }

            // anchorID が nil なら何も受け入れない（配置待ち）
            guard let currentSavedID = anchorID else { continue }

            // 保存済み ID に一致するアンカーのみ処理
            guard worldAnchor.id == currentSavedID else { continue }

            switch update.event {
            case .added, .updated:
                let pos = worldAnchor.originFromAnchorTransform.columns.3
                print("[ANCHOR-TRACE] 4️⃣ anchorUpdates event=\(update.event), isTracked=\(worldAnchor.isTracked), UUID=\(worldAnchor.id), pos=(\(pos.x), \(pos.y), \(pos.z))")

                self.anchor = worldAnchor
                if worldAnchor.isTracked {
                    applyAnchorTransform(worldAnchor)
                } else {
                    print("[ANCHOR-TRACE] 4️⃣ ⏳ Not tracked yet, waiting...")
                    setAnchorTransform(nil)
                }
            case .removed:
                print("[WorldAnchorManager] Anchor removed: \(worldAnchor.id)")
                anchor = nil
                setAnchorTransform(nil)
            }
        }
    }

    /// anchor の originFromAnchorTransform をそのまま anchorTransform にセットする
    private func applyAnchorTransform(_ anchor: WorldAnchor) {
        guard anchor.isTracked else {
            let pos = anchor.originFromAnchorTransform.columns.3
            print("[WorldAnchorManager] ⏳ Anchor not yet tracked, skipping. ID: \(anchor.id), pos: (\(pos.x), \(pos.y), \(pos.z))")
            setAnchorTransform(nil)
            return
        }

        setAnchorTransform(anchor.originFromAnchorTransform)
        let pos = anchor.originFromAnchorTransform.columns.3
        print("[WorldAnchorManager] 🔍 Applied anchor transform: pos=(\(pos.x), \(pos.y), \(pos.z)), ID: \(anchor.id)")
    }
    
    /// anchorTransform を更新し、sharedRenderState にも反映する
    private func setAnchorTransform(_ transform: matrix_float4x4?) {
        anchorTransform = transform
        sharedRenderState.withLock { $0.anchorTransform = transform }
    }
}
