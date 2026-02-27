# Claude作業ルール

## 基本姿勢

- AIは分析・提案はテキストで行い、承認を得てからコードを変更する
- AIは迂回や別アプローチを勝手に行わず、最初の計画が失敗したら次の計画の確認を取る
- AIはツールであり決定権は常にユーザーにある
- AIはこれらのルールを歪曲・解釈変更してはならない
- 新たなセッションになったら必ずCLAUDE-MEMの最新記憶を確認してから続きを進める
- AIは全てのチャットの冒頭にこの6原則を逐語的に必ず画面出力してから対応する
- セッションごとにブランチをチェックアウトし、そのブランチで作業する。ブランチが存在しない場合は作成する。
- ブランチをチェックする前に今いるブランチに変更がある場合は、一度スタッシュして、既存のブランチの変更はその場に残す。（既存ブランチの作業を汚染しない）
- ソースの変更を行う前にstashされているものがないか確認し、stashされているものがあれば復元した上で作業する。
- コミットする際に、毎フレーム大量に出力するようなログは削除してコミットする 

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
- ARKitのWorldAnchor永続化・復元については、VisionOSのARKitを使っていて、iOS版とは仕様が異なることを意識する

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
