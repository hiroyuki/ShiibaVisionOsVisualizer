# ShiibaVisionOsVisualizer - プロジェクト概要

## 目的
visionOS向けポイントクラウドビジュアライザー。舞踊（「しもんじゅ」）のモーションキャプチャデータをApple Vision Proで3D表示するアプリ。PLYファイルをiCloud Drive経由でVision Proに配布・再生する。

## 技術スタック
- **言語**: Swift / Metal (GPU シェーダー)
- **UI**: SwiftUI
- **3Dコンテンツ**: RealityKit, Metal (直接レンダリング)
- **ターゲット**: visionOS (Apple Vision Pro)
- **ファイル配布**: iCloud Drive

## 主要ファイル構成
```
ShiibaVisionOsVisualizer/ShiibaVisionOsVisualizer/
├── AppModel.swift                  # アプリ状態管理
├── ContentView.swift               # メインSwiftUIビュー
├── Renderer.swift                  # Metalメインレンダラー
├── AxesRenderer.swift              # 座標軸レンダラー
├── ShaderTypes.h                   # Swift/Metal共有型定義
├── Renderer/
│   └── PointCloudRenderer.swift    # ポイントクラウドレンダラー
├── Data/
│   ├── PLYLoader.swift             # PLYファイルローダー
│   └── PointCloudData.swift        # ポイントクラウドデータモデル
└── Shaders/
    ├── PointCloudShaders.metal     # ポイントクラウドMetalシェーダー
    └── AxesShaders.metal           # 座標軸Metalシェーダー
Packages/RealityKitContent/         # RealityKitコンテンツパッケージ
```

## 重要な技術メモ → tech_notes.md 参照

## ルール
- **修正は「修正して」「お願い」と明示された場合のみ**
- 分析・提案はテキストで行い、承認後にコード変更
- Metalファイルは `Shaders/` 直下のみ（`Renderer/` には置かない）
