# ShiibaVisionOsVisualizer

## PLYファイルの受け渡し仕様

### 概要

PLYファイルはアプリバンドルには含めず、iCloud Drive経由でVision Proに配布する。

### ディレクトリ構成

```
iCloud Drive (iCloud.jp.p4n.ShiibaVisionOsVisualizer)
└── Documents/
    └── Shimonju/          ← ダンス名ごとにフォルダを作成
        ├── shimonju_sf_000001.ply
        ├── shimonju_sf_000002.ply
        ├── ...
        └── shimonju.wav   ← オーディオファイル（任意）
```

### オーディオファイル

- PLYと同じ `Shimonju/` フォルダに音声ファイルを1つ置くと、アニメーション再生と同時に再生される
- 対応フォーマット: `mp3` / `wav` / `m4a` / `aac`
- ループなし、1回のみ再生
- **注意**: 一般の iCloud Drive（`com~apple~CloudDocs`）ではなく、アプリ専用コンテナ（`iCloud~jp~p4n~ShiibaVisionOsVisualizer`）に置くこと

### Mac でアプリコンテナを開く方法

`~/Library` はデフォルトで非表示のため、以下のいずれかでアクセスする。

**Terminal:**
```bash
open ~/Library/Mobile\ Documents/iCloud~jp~p4n~ShiibaVisionOsVisualizer/
```

**Finder:**
Cmd+Shift+G → `~/Library/Mobile Documents/iCloud~jp~p4n~ShiibaVisionOsVisualizer/` と入力

### Mac側の手順

1. iCloud Driveのアプリコンテナにフォルダを作成

```bash
mkdir -p ~/Library/Mobile\ Documents/iCloud~jp~p4n~ShiibaVisionOsVisualizer/Documents/Shimonju
```

2. PLYファイルをそのフォルダにコピー

```bash
cp -r /path/to/ply_files/ \
  ~/Library/Mobile\ Documents/iCloud~jp~p4n~ShiibaVisionOsVisualizer/Documents/Shimonju/
```

3. iCloudが自動的にアップロードする（46GB、時間がかかる）

### Vision Pro側の挙動

- アプリ起動時に `prefetchAllFiles()` が呼ばれ、未ダウンロードのファイルのダウンロードをiCloudにリクエストする
- ダウンロード済みのファイルから順次再生可能

### 前提条件

- Vision ProでiCloud Driveがオンになっていること
  `設定 → Apple Account → iCloud → iCloud Drive: オン`
- 同じApple IDでMacとVision Proがサインインしていること

### PLYファイルフォーマット

- フォーマット: `binary_little_endian`
- 1点あたり: 27 bytes (packed)
- ファイルサイズ: 約4.27 MB / ファイル
- 点数: 約165,639点 / ファイル
- 合計: 11,418ファイル、約46GB
