# 開発コマンド

## ビルド・実行
- **Xcode** でビルド・実行（visionOS シミュレーター or 実機）
- `xcodebuild -scheme ShiibaVisionOsVisualizer -destination 'platform=visionOS Simulator,...'`

## iCloud ファイル管理（Mac側）
```bash
# iCloud Driveにフォルダ作成
mkdir -p ~/Library/Mobile\ Documents/iCloud~jp~p4n~ShiibaVisionOsVisualizer/Documents/Shimonju

# PLYファイルをコピー
cp -r /path/to/ply_files/ \
  ~/Library/Mobile\ Documents/iCloud~jp~p4n~ShiibaVisionOsVisualizer/Documents/Shimonju/
```

## Git
```bash
git status
git log --oneline -10
git diff
git add <file>
git commit -m "メッセージ"
```

## ファイル検索（Darwin）
```bash
find . -name "*.swift"
ls -la
grep -r "pattern" --include="*.swift" .
```

## テスト・Lint
- 専用のテストターゲット/lintツールは特になし
- Xcodeのビルド成功をもって確認

## ブランチ
- メインブランチ: `main`
- 現在: `worldAnchorPlacement`
