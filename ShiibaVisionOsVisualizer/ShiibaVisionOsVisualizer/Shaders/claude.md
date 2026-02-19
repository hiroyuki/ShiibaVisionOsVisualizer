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
- `float3` はMetal bufferで12バイト（packed）だが、Swift `SIMD3<Float>.stride` は16バイト。混在注意
- `PointVertex` は `float4 position + float4 color = 32 bytes` で定義し、Swift側も `SIMD3<Float>.stride * 2 = 32 bytes` で確保（一致している）

### ビルボードサイズ

- `offset = uv * spriteSize / clipCenter.w` → 近いほど大きく・遠いほど小さい（物理的に自然）
- `offset = uv * spriteSize * clipCenter.w` → 逆遠近法（NG）
- `offset = uv * spriteSize` → 常に一定サイズ（物理的におかしい）

### PLYファイル

- フォーマット: `binary_little_endian`、27 bytes/point（packed）
- `Bundle.main` に Target Membership + Copy Bundle Resources が必要
- ファイル名の大文字小文字はシミュレーターでは無視されるが**実機では区別される**
