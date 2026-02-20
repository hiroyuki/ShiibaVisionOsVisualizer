# Claude作業ルール

## 基本姿勢

- **修正は明示的に「修正して」「お願い」と言われた場合のみ行う**
- 分析・提案はテキストで行い、承認を得てからコードを変更する
- 勝手にコードを変更しない

## プロジェクト構造

```
ShiibaVisionOsVisualizer/
├── Shaders/
│   └── PointCloudShaders.metal   ← Metalシェーダーはここ
├── Renderer/
│   ├── Renderer.swift
│   ├── PointCloudRenderer.swift
│   └── PointCloudData.swift
├── Loader/
│   └── PLYLoader.swift
├── ShaderTypes.h                  ← Swift/Metal共有の型定義
└── ContentView.swift
```

- **Metalファイルは `Shaders/` 直下**。`Renderer/` には置かない

## 技術メモ

### visionOS / Metal

- `rasterization rate map` が有効な場合、`.point` プリミティブは使用不可（`only triangles may be drawn`）
- ポイントクラウドの描画は **instancing + triangle quad（6頂点）** で対応
  - `drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: pointCount)`
- `float3` はMetal bufferで12バイト（packed）だが、Swift `SIMD3<Float>.stride` は16バイト。混在注意
- `PointVertex` は `float4 position + float4 color = 32 bytes` で定義し、Swift側も `SIMD3<Float>.stride * 2 = 32 bytes` で確保（一致している）

### ビルボード方式

- ワールド空間でカメラの right/up ベクトルを使って billboard を組み立て、そのまま投影するのが物理的に正確
- view-projection 行列の行成分から camRight / camUp を取り出す:
  ```metal
  float3 camRight = float3(vp[0][0], vp[1][0], vp[2][0]);
  float3 camUp    = float3(vp[0][1], vp[1][1], vp[2][1]);
  float3 worldOffset = (camRight * uv.x + camUp * uv.y) * physicalSize;
  float4 clipPos = vp * (worldPos + float4(worldOffset, 0.0));
  ```
- `physicalSize` は半径（メートル）。0.005 = 直径1cm
- クリップ空間でオフセットする方式（`/ clipCenter.w` や `* clipCenter.w`）は不自然になるので使わない

### PLYファイル

- フォーマット: `binary_little_endian`、27 bytes/point（packed）
- `Bundle.main` に Target Membership + Copy Bundle Resources が必要
- ファイル名の大文字小文字はシミュレーターでは無視されるが**実機では区別される**
