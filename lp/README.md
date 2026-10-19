# ねこのまど LP（下書き）

まど付きで一般公開するときの紹介ページの下書き。2026-10-20 作成。

- このフォルダは GitHub Pages の公開元（`docs/`）の外にあるので、main にマージしても公開されない。
- ページ上部の「下書き（未公開）」の帯と、点線の「公開前に決める」枠は、公開前に外す。
- `<meta name="robots" content="noindex, nofollow">` も公開時に外す。

## 見かた

```bash
python -m http.server 5193 --bind 127.0.0.1 --directory lp
```

ブラウザで http://127.0.0.1:5193/ を開く。ビルドは不要（HTML と CSS だけ）。

## 構成

| 順 | 区画 | 伝えること |
|---|---|---|
| 1 | はじめ | 猫の写真に毎日会える。まどで家族や猫友に届けられる |
| 2 | 01 見つける | iPhoneの中で猫の写真を見つける。元の写真はそのまま |
| 3 | 02 ウィジェット | ホーム画面で1日1枚、猫の写真に再会する |
| 4 | 03 まど | 作る・招待 → ひとことと1枚を届ける → ホーム画面に届く・ハート。招待した人だけ・暗号化・届ける前の確認 |
| 5 | これからのまど | 6人まで入れるまど、猫カフェ・保護猫のまど（準備中・構想中と明記） |
| 6 | ほかにも | 自分だけのメモ、暮らしのツール |
| 7 | 写真の扱い | 判定は端末内、元写真を消さない、届くのは選んだ1枚、広告なし |
| 8 | 料金 | 招待されて入るのは無料。作れるまど 無料1つ／有料（月額980円）5つまで。まどの決まり |
| 9 | よくある質問 | 写真アプリとの違い、家族の準備、届いた写真の期限、センシティブな内容の警告、対応機種 |

## 文言の根拠

- まどの決まり・料金：所有者の決定（2026-10-20、`ねこのまど_UIUX改善案.md` 1-8）と ADR-024。人数を課金要素にしない。
- 写真の扱い：アプリのコード（origin/main 65eca48）で確認。猫の判定は Vision による端末内処理、写真は長辺2048pxに縮小して位置情報を取り除き、エンドツーエンド暗号化。届いた写真は最長90日。送る前に SensitiveContentAnalysis で確認。外部の解析SDKなし。
- 未実装のもの（3人以上のまど、猫カフェ・保護猫のまど）は「準備中」「構想中」として、使える機能と分けて書いた。本の注文、クラウド保管、公式まどは載せていない。

## 公開前に決めること

1. 写真・アルバム・ウィジェット・メモ・ツールのうち、無料で使える範囲と有料プランに含めるもの
2. 無料で試せる期間の有無と日数、年払いの有無
3. 公開する場所（GitHub Pages のトップを置き換える／別のパスに置く／今の chatgpt.site のLPを差し替える）

## 公開前にアプリ側と合わせること

- 今のアプリは「1つのまど2人まで・1台で3つまで・1人4台まで」。LPの決まり（6人まで・無料1つ／有料5つ・3台まで）と、公開する版の動きを合わせる。6人は「準備中」と書いてある。
- アプリ内の会員の設計（まどを作るのは会員だけ、まど最大3つ）は、10/20の決定（無料で1つ作れる）と違う。
- 通常のRelease構成では、まどの共有と課金が既定でオフ。まど付きで公開する構成ができてから、このLPを公開する。

## 写真

すべて Unsplash の写真（[Unsplash License](https://unsplash.com/license)）。元のLPプロジェクト（`C:\dev\neko-lp-offer-alignment-20261001\public\sample`）から縮小して WebP にした。利用者の写真や体験談ではない。

| ファイル | 撮影者 | 出典 |
|---|---|---|
| photo-sofa.webp | Adam Stefanca | https://unsplash.com/photos/cat-on-sofa-ZT5mTdznDco |
| photo-stretch.webp | Adam Stefanca | https://unsplash.com/fr/photos/chat-maine-coon-marron-sur-pouf-kaywPrM99mI |
| photo-lap.webp | David R Pariente | https://unsplash.com/photos/a-cat-lying-on-a-persons-lap-14XsmkyznWw |
| photo-grey-bed.webp | Milada Vigerova | https://unsplash.com/photos/russian-blue-cat-on-white-and-blue-textile-JLN0U5Rj0gg |
| photo-grey-ball.webp | Milada Vigerova | https://unsplash.com/photos/russian-blue-cat-lying-on-white-textile-l6sfaRON_qE |
| photo-grey-yawn.webp | Milada Vigerova | https://unsplash.com/photos/russian-blue-cat-on-white-bed-cyv4x8ReGns |
| photo-grey-chair.webp | Milada Vigerova | https://unsplash.com/photos/short-fur-gray-cat-on-gray-fabric-sofa-chair-s7kuB1CKXjw |
| photo-two-cats.webp | Shawn Rain | https://unsplash.com/photos/two-cats-are-cuddling-close-together-MUWUfvXpdag |
| photo-everyday-food.webp | Elena Leya | https://unsplash.com/photos/a-colorful-salad-bowl-with-many-fresh-ingredients-_vy3L5n8VnI |
| photo-everyday-landscape.webp | Luca Bravo | https://unsplash.com/photos/brown-house-near-body-of-water-zAjdgNXsMeg |
| photo-everyday-table.webp | Marc Pell | https://unsplash.com/photos/a-coffee-table-with-a-cup-of-coffee-on-it-s11Li3T8J24 |

アイコンと窓の猫の絵（`app-icon-180.png`、`cat-*.webp`）は、アプリのアイコンと元のLPの素材から作った。
