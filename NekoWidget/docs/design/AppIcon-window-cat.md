# アプリアイコン: 窓からのぞく猫

2026-09-19、利用者の依頼で、LPで採用した猫のアイコンにアプリ側も揃えた。

## 正本と書き出し先

- 正本: `AppIcon-window-cat-master.png`（1254 × 1254、RGB、透過なし）
- 採用済みの元画像: `G1-squished-cheeks.png`（ぎゅうぎゅう・ほっぺがむにゅ）。LPの `cat-squish.webp` と同じ元画像。
- 正本 SHA-256: `f7c021389d86845eb6219a39d4eea226c20b4040aae7840882e63a06bd0b07de`
- ホーム画面: `../../NekoWidget/Assets.xcassets/AppIcon.appiconset/AppIcon.png`
- 初回案内: `../../NekoWidget/Assets.xcassets/OnboardingAppIcon.imageset/OnboardingAppIcon.png`

正本を Lanczos3 で 1024 × 1024 に縮小し、sRGB・透過なしの PNG として両方へ同じ画像を書き出す。構図の変更や角丸の焼き込みはしない。外周のマスクは iOS / 表示側に任せる。

書き出し画像 SHA-256: `ec0b45228e55016a46be698f9b8871b467b0a2888650d62250b457228ff56212`

既存の `AppIcon-P1-master.svg` は旧「窓だけ」アイコンの資料として残す。現行アイコンの再書き出しには使用しない。

## 確認範囲

- 1024 × 1024、透過なし、両アセットが同一画像であることを確認。
- 60 px / 120 px の書き出しを目視し、窓・猫の耳・目の見え方を確認。
- アセット名と Xcode の AppIcon 設定を維持。Swift、署名、バージョン、課金などは変更していない。
- Windows 上での画像確認のみ。Xcode ビルド、iPhone 実機、TestFlight 配布は今回の確認に含まない。

作業ブランチ: `codex/app-icon-window-cat-20260919`。着手時の本線は `7e71b66`。この記録だけでは本線への取り込み・配布を意味しない。
