# しまい箱 サポートサイト

App Store提出用の静的サポートサイトです。Cloudflare Pages では、この `support-site` ディレクトリをRoot directoryに指定します。

## 公開構成

- GitHub repo: `kk0320/shimaibako`
- Root directory: `support-site`
- Framework preset: `None`
- Build command: `exit 0`
- Build output directory: `.`

## 主なページ

- `/index.html`: トップページ
- `/support.html`: サポートページ
- `/privacy.html`: プライバシーポリシー
- `/faq.html`: よくある質問

App Store Connectで利用する想定URL:

- サポートURL: `/support.html`
- プライバシーポリシーURL: `/privacy.html`

## 運用メモ

- 外部API、解析タグ、広告、外部CDN、問い合わせフォーム送信機能は使いません。
- 問い合わせ先メールは `kai.nomura2525@outlook.com` です。
- しまい箱は、写真アプリ本体の元写真・元動画を削除・移動・変更しません。
