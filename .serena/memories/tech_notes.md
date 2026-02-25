# 技術メモ - visionOS / Metal

## visionOS レンダリング制約
- `rasterization rate map` が有効な場合、`.point` プリミティブは使用不可（`only triangles may be drawn`）
- ポイントクラウドの描画は **instancing + triangle quad（6頂点）** で対応
  ```swift
  drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: pointCount)
  ```

## Swift/Metal 型サイズの注意
- `float3` はMetal bufferで **12バイト（packed）**
- Swift `SIMD3<Float>.stride` は **16バイト**
- → 混在注意。`PointVertex` は `float4 position + float4 color = 32 bytes` で統一

## ビルボード描画方式
- ワールド空間でカメラの right/up ベクトルを使って billboard を組み立て
- view-projection 行列の行成分から取り出す:
  ```metal
  float3 camRight = float3(vp[0][0], vp[1][0], vp[2][0]);
  float3 camUp    = float3(vp[0][1], vp[1][1], vp[2][1]);
  float3 worldOffset = (camRight * uv.x + camUp * uv.y) * physicalSize;
  float4 clipPos = vp * (worldPos + float4(worldOffset, 0.0));
  ```
- `physicalSize`: 半径（メートル）。0.005 = 直径1cm
- クリップ空間オフセット方式は使わない（不自然になる）

## PLYファイル
- フォーマット: `binary_little_endian`、**27 bytes/point（packed）**
- 約165,639点/ファイル、約4.27MB/ファイル、合計11,418ファイル（46GB）
- iCloudコンテナ: `iCloud~jp~p4n~ShiibaVisionOsVisualizer`
- ファイル名の大文字小文字: シミュレーターでは無視されるが**実機では区別される**

## iCloud配布
- iCloud Drive経由でVision Proに配布
- Mac側: `~/Library/Mobile Documents/iCloud~jp~p4n~ShiibaVisionOsVisualizer/Documents/[ダンス名]/`
- アプリ起動時に `prefetchAllFiles()` で未ダウンロードファイルをリクエスト

## ShaderTypes.h (Swift/Metal共有)
- `BufferIndex`: MeshPositions=0, MeshGenerics=1, Uniforms=2, ViewProjection=3, PointCloudInput=4, PointCloudOutput=5
- `ViewProjectionArray`: `matrix_float4x4 viewProjectionMatrix[2]`（両眼用）
- `Uniforms`: `matrix_float4x4 modelMatrix`
