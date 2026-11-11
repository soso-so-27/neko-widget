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

App Store の画面写真（5枚）と同じ向き。各区画は「大きな1行（確かに、と思うこと）→ こたえの1行（青い下線）→ 絵（淡い青の台・足あと・ふきだし・無料の札・のわ）」の順。

| 順 | 区画 | 大きな1行 → こたえ | のわ |
|---|---|---|---|
| 1 | はじめ（＋ウィジェットの補足 `#widget`） | 撮るだけ撮って、見返せていない。→ 毎日ちがう1枚が、ホーム画面に。（無料） | peek |
| 2 | まど `#mado` | かわいい1枚が、トークだと流れる。→ 家族の1枚は、ホーム画面に届く。（招待された家族は無料）。3つの手順、約束、これから | wave |
| 3 | 見つける `#find` | ひらけば、ぜんぶ猫。→ スクショもレシートも、まざらない。（無料） | roll |
| 4 | 月のアルバム `#album` | この子との毎日は、あっという間。→ 毎月1日、先月がアルバムになる。（Plus・14日間無料）。自分だけのメモ | groom |
| 5 | 暮らしのツール `#more` | もしものとき、この子を守る準備。→ チラシも、診察メモも、すぐ作れる。（無料） | jump |
| 6 | 写真の扱い `#privacy` | 判定は端末内、元写真を消さない、届くのは選んだ1枚、広告なし | — |
| 7 | 料金 `#price` | 入れる → 14日間すべて無料 → 気に入ったら月額980円 → やめても消えない。無料／Plus。まどの決まり | peek_wink（Plusの札） |
| 8 | よくある質問 `#faq` | 写真アプリとの違い、家族の準備、家族の支払い、14日後のこと、届いた写真の期限、センシティブな内容の警告、対応機種 | — |
| 9 | おわりに | 公開まで、もう少しお待ちください。 | sit_up |

絵はすべて HTML と CSS で組んだ見本（素材写真を使う）。画面写真の元画像は使っていない。迷子のチラシの名前と連絡先（090-0000-0000）は見本。

## 文言の根拠

- まどの決まり・料金：所有者の決定（2026-10-20、`ねこのまど_UIUX改善案.md` 1-8）と ADR-024。人数を課金要素にしない。
- 写真の扱い：アプリのコード（origin/main 65eca48）で確認。猫の判定は Vision による端末内処理、写真は長辺2048pxに縮小して位置情報を取り除き、エンドツーエンド暗号化。届いた写真は1つのまどにつき新しいものから500枚（日数の期限なし）。送る前に SensitiveContentAnalysis で確認。外部の解析SDKなし。
- 未実装のもの（3人以上のまど、猫カフェ・保護猫のまど）は「準備中」「構想中」として、使える機能と分けて書いた。本の注文、クラウド保管、公式まどは載せていない。

## 料金の決まり（2026-10-20）

`ねこのまど_980円への階段_1020.md`（claude-main）に根拠をまとめた。

- 無料の範囲ですぐ使える。Plus（月額980円）は App Store のお試しオファーで14日間無料（申し込みが要る。アプリ側で日数を数える無料開放は2026-10-20午後に撤回）。Plusは「育つもの」（自分の猫のウィジェットの新しい1枚、月のまとめ・季節のムービー、新しいメモ、まどを作る・続ける、保存）。
- まどは作った人がPlusで続ける。入る人はずっと無料。お試し中も作れる（2026-10-20昼の追加決定で「1つ目はずっと無料」を撤回）。
- 月額980円だけ。年額は継続のデータが出てから。保存と復元は980円に含める（枠の数字は保存の公開時に決める）。
- ツール5つはすべて無料。
- Appleのファミリー共有は 1.0 ではオフ（2026-10-30 所有者決定、ADR-027 の 4 を取り消し）。招待された家族は、まど・家族の手帳を無料で使える。

## 公開前に決めること

1. 公開する場所（GitHub Pages のトップを置き換える／別のパスに置く／今の chatgpt.site のLPを差し替える）

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

アイコン（`app-icon-180.png`）はアプリのアイコンから作った。黒猫「のわ」（`nowa-*.webp`）は公式キャラクターの素材（透過PNG）を長辺640pxのWebPにしたもの。飾りなので alt は空。
