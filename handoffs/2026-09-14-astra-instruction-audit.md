# Astra向けのスキル・開発指示の見直し

2026-09-14。利用者の「公式に合わせてスキル見直しを進めて」に対応。対象は、この開発で使うOpenAI Docsと有効なプロジェクト指示。アプリ・CI・配信・モデル設定は変更しない。

根拠: OpenAI公式の [Rethinking skills and prompts for GPT-6 Astra](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra)（2026-09-11）と、導入済みの `skill-creator`。発動条件を限定し、必要な参照先だけ読む構成へ改め、検証・権限・完了条件を実際の作業に合わせた。

## 反映した変更

| 対象 | 変更 |
|---|---|
| ローカル `openai-docs/SKILL.md` | 説明を459→152文字、入口全体を5,433→3,028文字へ短縮。一般のアプリ作業との境界を明確化。スキル監査をAPI移行から分け、不要なresolver・APIキー要求を防ぐ |
| OpenAI Docsの関連4資料 | model-migration、model-selection、official-docs、codex-self-knowledgeを整理。現在の作業で確認済みの根拠を再利用。毎回の検索・マニュアル取得の固定手順を取り除き、実際に不足する情報だけ補う |
| OpenAI DocsのUI設定 | 短い説明と `$openai-docs` の起動文を整合。既存アイコン・自動選択設定を維持 |
| 本線 `AGENTS.md` | 2,529→1,486文字。共有・Widgetという分類名ではなく、保存・送信先・権限・更新整合性など実際の変更リスクで検証量を判断 |
| [開発・配布手順](development-release-workflow.md) | 常設指示からCI・配布時の詳細を分離。旧節の条件を保持し、該当場面で必要な節だけ読む |
| 現在の作業場所の `AGENTS.md` | 本線checkoutの指示への入口を追加。重複した保存制約を整理し、並行数・履歴複製・ディスク残量・履歴操作の保護を維持 |

文字数はUTF-8読取後の文字数で、トークン数や速度の実測ではない。

## 保持した条件と確認

- 明示されたモデル、API契約、代替経路、非対象設定を維持する。可逆な作業でも依頼範囲を広げない。
- 研究worktreeを編集しない。一般公開・外部招待／提出・課金開始には今回の許可を流用しない。
- privacy・署名・migration・fail-closed、候補→mainの成功証拠、24時間・ancestor・同一入力の条件、配布CLIのdry-run・重複防止を保持。
- 指示文の簡素化はCI判定の省略を認めるものではない。現行workflowのpath指定ではrootのAGENTSとhandoffsだけの変更はiOS CI対象外。アプリ等と混在すれば現行の全範囲判定になり得る。
- スキルvalidator、UI metadata、参照リンクの存在、差分を確認。別担当が文言だけの変更／Astraスキル監査／共有解除とWidget不具合から内部配布／GPT-5.6固定のプロンプト改善の4場面を机上確認。実作業の時間短縮やモデルの全ケースでの動作を証明したものではない。

## ローカル反映の所在

- スキル: `C:/Users/soya_/.codex/skills/.system/openai-docs/`
- 作業場所の指示: `C:/Users/soya_/OneDrive/ドキュメント/ChatGPT/アプリ3/AGENTS.md`
- 変更前の指示ファイルの控え: `C:/dev/neko-astra-instructions-20260914/output/instruction-backup/`

導入済み `skill-creator` は今回の公式方針と整合しており、変更不要。無関係なプラグインの技能本文は未監査・未変更。スキルの複製・追加や一括無効化も行っていない。ローカルのsystem skillは将来の配布更新で上書きされる可能性があるため、以後この問題が再発した場合は現物と本記録を照合する。履歴ファイルの操作は行っていない。

この見直しにアプリの新しいTestFlightは不要。アプリは164アップロード済みの状態を維持し、接続・画質・継続価値などの残件は[現在の台帳](2026-09-13-current-task-board.md)で引き続き扱う。
