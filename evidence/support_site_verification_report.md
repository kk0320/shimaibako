# サポートサイト公開確認レポート

## 確認日時

2026-06-18 13:42:00 JST

## 確認したURL

- https://shimaibako.pages.dev/
- https://shimaibako.pages.dev/support.html
- https://shimaibako.pages.dev/privacy.html
- https://shimaibako.pages.dev/faq.html

## PC幅表示の確認結果

表示幅1440pxで確認した。

| ページ | 結果 | 確認内容 |
| --- | --- | --- |
| トップ | PASS | アプリ名、概要、サポート/プライバシーポリシー/FAQリンク、元写真・元動画を削除・変更しない説明を確認 |
| サポート | PASS | 問い合わせ先メール、安全方針、問い合わせ時に書く内容、写真送付を控える案内を確認 |
| プライバシーポリシー | PASS | 基本方針、端末内処理、アプリ削除時の扱い、問い合わせ先、第三者提供なしを確認 |
| FAQ | PASS | 指定された6件のQ&Aを確認 |

横スクロールは検出されなかった。

## スマホ幅表示の確認結果

表示幅390pxで確認した。

| ページ | 結果 | 確認内容 |
| --- | --- | --- |
| トップ | PASS | 見出し、リンク、安全説明が読みやすく表示されることを確認 |
| サポート | PASS | 問い合わせ先メール、注意事項、問い合わせ時の記載項目が表示されることを確認 |
| プライバシーポリシー | PASS | 上部、中部、下部を撮影し、必須項目が表示されることを確認 |
| FAQ | PASS | 上部と下部を撮影し、Q&Aが読みやすいことを確認 |

横スクロールは検出されなかった。文字サイズはスマホ幅でも読める大きさだった。

## リンク確認結果

ページ内の内部リンクを確認した。

- トップから `support.html`、`privacy.html`、`faq.html`: PASS
- サポートからトップ、プライバシーポリシー、FAQ: PASS
- プライバシーポリシーからトップ、サポート、FAQ: PASS
- FAQからトップ、サポート、プライバシーポリシー: PASS
- メールリンク `mailto:kai.nomura2525@outlook.com`: PASS

リンク切れは検出されなかった。

## メールアドレス表示確認

`kai.nomura2525@outlook.com` は以下で確認した。

- `support.html`: PASS
- `privacy.html`: PASS
- `README.md`: PASS

## プライバシーポリシー必須項目の確認

| 項目 | 結果 |
| --- | --- |
| ログインなし | PASS |
| 広告なし | PASS |
| トラッキングなし | PASS |
| 外部送信なし | PASS |
| 写真/OCR/分類/メモ/タグは端末内で扱う | PASS |
| 元写真・元動画は削除・変更しない | PASS |
| 不要候補はしまい箱内だけの表示状態 | PASS |
| アプリ削除時、しまい箱内の設定/OCR/分類/履歴は消える可能性がある | PASS |
| 写真アプリ側の元写真・元動画、iCloud写真の原本は残る | PASS |
| サポートメールを送った場合のみ、メール本文に含まれる情報を問い合わせ対応に使う | PASS |
| 第三者提供なし | PASS |
| 問い合わせ先メール | PASS |

## サポートページ必須項目の確認

| 項目 | 結果 |
| --- | --- |
| 問い合わせ先メール | PASS |
| 返信には時間がかかる場合がある | PASS |
| 元写真・元動画は削除・変更しない | PASS |
| アプリ内の分類/OCR/履歴はアプリ削除時に消える可能性がある | PASS |
| フル/全件読み込みは時間がかかる場合がある | PASS |
| 不具合問い合わせ時に書いてほしい情報 | PASS |
| 写真そのものや個人情報を含むスクリーンショットは必要な場合を除き送らない案内 | PASS |

## 外部送信/解析タグ/外部CDNの有無

- 外部リクエスト: なし
- 外部スクリプト: なし
- 外部CDN: なし
- 解析タグ: なし
- 広告タグ: なし
- 送信フォーム: なし
- 不要な画像や重いファイル: なし

Cloudflare PagesのRoot directoryを `support-site` にする前提と、公開ファイル構成に矛盾はなかった。

## スナップショット一覧

保存先: `evidence/support_site_snapshots/`

- `desktop_index_top.png`
- `desktop_support_top.png`
- `desktop_privacy_top.png`
- `desktop_privacy_middle.png`
- `desktop_privacy_bottom.png`
- `desktop_faq_top.png`
- `mobile_index_top.png`
- `mobile_support_top.png`
- `mobile_support_middle.png`
- `mobile_support_bottom.png`
- `mobile_privacy_top.png`
- `mobile_privacy_middle.png`
- `mobile_privacy_bottom.png`
- `mobile_faq_top.png`
- `mobile_faq_bottom.png`

合計15枚。

## 問題点

公開サイト上の重大な問題は見つからなかった。

## 修正が必要な場合の提案

現時点で必須修正はない。将来サポート情報を追加する場合も、外部フォームや解析タグを入れず、静的HTMLの範囲で更新する。

## App Store Connectに入力するURL

- Support URL: https://shimaibako.pages.dev/support.html
- Privacy Policy URL: https://shimaibako.pages.dev/privacy.html
