# コードスタイルと規約

## 言語・フレームワーク
- Swift 5.x
- SwiftUI for UI
- Metal for GPU rendering
- RealityKit for immersive scenes

## 命名規則
- クラス・構造体: UpperCamelCase（例: `PointCloudRenderer`, `AppModel`）
- 関数・変数: lowerCamelCase（例: `prefetchAllFiles()`, `pointCount`）
- 定数: `k` プレフィックス（例: `kBufferIndexUniforms`）
- Metal シェーダー関数: snake_case or lowerCamelCase

## コメント
- 日本語コメントあり（プロジェクトオーナーは日本語話者）
- 英語コメントも混在

## ファイル配置ルール
- Metalシェーダー → `Shaders/` ディレクトリのみ
- レンダラークラス → `Renderer/` ディレクトリ
- データモデル・ローダー → `Data/` ディレクトリ
- Swift/Metal共有型定義 → `ShaderTypes.h`

## 重要な設計パターン
- レンダラーはクラスベース（`Renderer`, `PointCloudRenderer`, `AxesRenderer`）
- バッファインデックスは `ShaderTypes.h` で定義し Swift/Metal で共有
- 両眼レンダリング: `ViewProjectionArray` に2つの行列を格納
- ポイントクラウド: Computeシェーダーで変換 → Vertexシェーダーで描画

## 作業ルール（claude.md準拠）
- コード変更は明示的に依頼された場合のみ
- 提案 → 承認 → 変更 の順序を守る
