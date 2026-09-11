# targets.txt 導入と AI エージェント CLI 追加（plan）

日付: 2026-09-11

## 目的

cli-toolbox の導入対象管理をコード内 `STANDARD_SET` からルート直下の `targets.txt` へ移行し、AI エージェント CLI を既存の provider/install 基盤へ統合する。

## 基本方針

役割を次のように分離する。

```text
targets.txt   = 利用者がインストール・更新したい CLI
SUPPORTED_CLIS = cli-toolbox が対応している全 CLI
manifest.tsv  = cli-toolbox が実際に導入した CLI の内部記録
```

`manifest.tsv` は廃止しない。provider、version、path、cli-toolbox による所有権の判定に引き続き使用する。`targets.txt` の内容から manifest を再生成しない。

## targets.txt 仕様

リポジトリルートに `targets.txt` を追加する。

初期内容（`STANDARD_SET` 相当 + AI agents）:

```text
# Core cloud/ops CLIs
uv
gh
tccli
aws
gcloud
az
terraform

# AI agents
opencode
agent       # Cursor Agent CLI
codebuddy
claude
codex
agy
```

ファイル仕様:

- 1 行 1 CLI
- 空行を無視
- 行頭が `#` の行を無視
- 行末の `# コメント` を除去
- 前後の空白を除去
- 重複は 1 件として扱う
- 未知の CLI 名は黙って無視せずエラー
- ファイル不存在、または有効 CLI がゼロなら明確なエラー
- YAML などの外部パーサーは使わず、シェルだけで処理

## コマンド仕様

```bash
# targets.txt の有効な CLI をすべてインストール・更新
./cli-toolbox.sh install

# 指定された CLI だけインストール・更新
./cli-toolbox.sh install aws codex

# targets.txt の CLI を一覧表示
./cli-toolbox.sh list

# 指定された CLI だけ一覧表示
./cli-toolbox.sh list aws codex

# targets.txt の CLI を診断
./cli-toolbox.sh doctor

# cli-toolbox が管理する CLI だけ明示的に削除
./cli-toolbox.sh delete codex
```

引数を指定した場合は `targets.txt` を使用せず、指定された CLI だけを処理する。

`--ai`、`--cloud` などのカテゴリオプションは実装しない。

## コメントアウト時の動作

`targets.txt` で CLI をコメントアウトしても、自動削除しない。

コメントアウトは以下だけを意味する。

- 引数なし `install` の対象から外れる
- 引数なし `list` の対象から外れる
- 引数なし `doctor` の対象から外れる

削除は必ず明示的な `delete` / `remove` / `uninstall` で行う。

## manifest.tsv

現在の形式と役割を維持する。

```text
<cli>    <provider>    <version>    <path>
```

用途:

- cli-toolbox が導入した CLI かどうかの判定
- インストール方式の記録
- バージョンと配置先の記録
- 安全な更新と削除
- system / Homebrew / 利用者が別途導入した CLI との区別

## AI エージェント CLI

以下を `SUPPORTED_CLIS` へ追加し、既存の provider/install/inspect/delete に統合する。

```text
opencode
agent
codebuddy
claude
codex
agy
```

注意事項:

- `agent` は Cursor Agent CLI。help と README では `agent (Cursor Agent CLI)` と明記
- AI 専用の別インストール基盤は作らない
- 各 CLI の公式 stable 版インストール方式を調査して provider を選ぶ
- 認証、ログイン、API キー設定は行わない
- npm 等を使う場合も、可能な限りユーザー領域で管理
- system / Homebrew / npm global 等の既存導入を勝手に更新・削除しない
- cli-toolbox 管理版の更新失敗時は既存の動作品を残す
- macOS/Linux で対応できない CLI は理由が分かる状態で `unsupported` にする
- インストール元・実行ファイル名・バージョン確認方法が不明確な CLIは推測で実装しない

## コード変更（想定）

- `targets.txt` を追加
- `STANDARD_SET` を廃止
- `targets.txt` を読み込む共通関数を追加（`lib/targets.sh`）
- `install` / `list` / `doctor` の引数なし処理を `targets.txt` 基準へ変更
- AI エージェントを `SUPPORTED_CLIS` と installer/provider へ追加
- usage/help、README、`docs/architecture.md`、`docs/adding-cli.md` を更新
- オフラインテストを追加・更新

内部レイヤ構成（`common` → `packages` → `providers` → `targets` → `installers`）は維持し、大規模な再設計はしない。

## テスト要件

最低限、以下をオフラインテストへ追加する。

- 空行とコメント行を無視する
- 行末コメントを除去する
- 重複を除去する
- 未知の CLI 名をエラーにする
- 引数なし `install` が `targets.txt` を使用する
- 引数あり `install` が指定 CLI だけを使用する
- コメントアウトした CLI を自動削除しない
- manifest に残っている管理対象を明示的に削除できる
- `agent` が Cursor Agent CLI として表示される
- 既存の system CLI を削除しない
- 更新失敗時に既存バイナリを維持する

## 完了条件

- `shellcheck` と `bash tests/test.sh` が成功する
- 変更ファイル、設計判断、未対応事項、テスト結果を report にまとめる
- 既存の正常な CLI やユーザー設定を変更・削除しない
