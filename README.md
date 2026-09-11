# cli-toolbox

クラウド/運用CLIを、ユーザー領域へ冪等に導入するツールです。Terraform の `apply` のような振る舞いをします。

```bash
./cli-toolbox.sh install            # 標準セットを stable 最新版へ収束（インストール＋更新）
./cli-toolbox.sh install gh glow    # 指定したCLIだけ収束
./cli-toolbox.sh doctor             # 環境と導入済みCLIの健康診断
./cli-toolbox.sh list               # 各CLIの状態一覧
```

- 実行のたびに公式の stable 最新版を確認し、状態を収束させます。
  - 未導入 → インストール
  - 古い → stable 最新版へ更新
  - stable 最新版 → 何もしない
  - 失敗 → 既存の正常なバイナリを保持
  - 管理対象外のCLI → 削除しない
- `update` コマンドはありません。`install` の再実行で stable 最新版へ収束します。
- Docker/Podman は使いません。シェル設定ファイルも変更しません。

## Python 製 CLI の管理方針

- **Python 製 CLI（`tccli`）は `uv tool` で隔離管理します**（`uv tool install --upgrade <pkg>`）。
- `pipx` は cli-toolbox の管理対象外です（インストールしません）。
- OS に `pipx` が既に入っていても、cli-toolbox は削除・上書きしません。`list` にも表示しません。
- `pip install --user`、グローバル `pip install`、独自 venv による新規導入は行いません。
- `uv` 自体は [公式 standalone installer](https://docs.astral.sh/uv/getting-started/installation/) で導入します（`curl | bash` は使わず、スクリプトをダウンロードしてから実行）。
- **AWS CLI v2** や **Azure CLI** など公式配布方式があるものは `uv` 管理にしません（`uv tool install awscli` は v1 になるため禁止）。
- cli-toolbox 管理外の既存 CLI（system / pipx / pyenv など）は勝手に削除・更新しません。

### tccli の移行

既存の pip / pipx / pyenv 配下に `tccli` がある場合:

- `list` では `STATE=migration-available` を表示します。
- `install tccli` は `uv tool install --upgrade tccli` を実行します。
- `~/.local/bin` が PATH 上で既存 `tccli` より優先されることを確認し、衝突時は警告します。
- 既存環境のアンインストールは行いません。

## 対応環境

- Linux amd64 / Linux arm64（主対象）
- macOS は設計上考慮していますが、現時点では未対応です（`install` はエラーになります）
- `gh` / `gcloud` / `az` は Debian/Ubuntu 系の APT 公式リポジトリを使用します（`sudo` が必要）

## セットアップ

```bash
git clone https://github.com/aktus-tk/cli-toolbox ~/github/aktus-tk/cli-toolbox
cd ~/github/aktus-tk/cli-toolbox

./cli-toolbox.sh install

# または PATH へ追加
export PATH="$HOME/github/aktus-tk/cli-toolbox:$PATH"
cli-toolbox.sh install
```

導入先はデフォルトで `~/.cloud-toolbox` です。`CLOUD_TOOLBOX_HOME` で変更できます。

```text
~/.cloud-toolbox/
├── bin/       # 導入されたCLIバイナリ/シンボリックリンク（PATHに追加）
├── state/     # manifest（cli-toolbox が記録した管理方式・バージョン）
├── tools/     # 展開されたツールツリー（aws-cli など）
└── lib/       # 予約
```

`tccli`（uv tool）は `~/.local/bin` に配置されます。`UV_TOOL_BIN_DIR` で変更できます。

## PATH 設定

```bash
export PATH="$HOME/.cloud-toolbox/bin:$HOME/.local/bin:$HOME/bin:$PATH"
```

`.bashrc` / `.zshrc` などへ追記してください（このツールは自動では編集しません）。

## 使い方

```bash
./cli-toolbox.sh install
./cli-toolbox.sh install tccli aws
./cli-toolbox.sh doctor
./cli-toolbox.sh list
./cli-toolbox.sh list tccli aws
./cli-toolbox.sh help
```

`install` を再実行するたびに公式 stable 最新版へ収束します。

## list の見方

| 列 | 意味 |
|---|---|
| STATUS | `managed` / `system` / `missing` / `requires-root` / `unsupported` |
| PROVIDER | `uv-tool` / `official-installer` / `official-package` / `release-binary` / `local-wrapper` / `system-package` / `unknown` |
| STATE | `unchanged` / `update-available` / `install-required` / `migration-available` / `unknown` |

例:

```text
CLI      STATUS   CURRENT   LATEST   PATH                    PROVIDER
tccli    managed  3.1...    3.1...   ~/.local/bin/tccli      uv-tool
aws      managed  2.x       2.x      ~/.cloud-toolbox/bin/aws official-installer
az       missing  -         2.77.0   -                       official-package
```

`requires-root` は APT 導入に `sudo` が必要な状態です。`sudo apt install ...` を実行してください。

## 標準セット

```bash
uv gh glow coscli tccli aws gcloud az
```

## CLI ごとの管理方式

| CLI | PROVIDER | 方式 |
|---|---|---|
| `uv` | official-installer | 公式 standalone installer |
| `tccli` | uv-tool | `uv tool install --upgrade tccli` |
| `aws` | official-installer | AWS CLI v2 公式インストーラー |
| `az` | official-package | Microsoft 公式 APT |
| `gh` | official-package | GitHub 公式 APT |
| `gcloud` | official-package | Google Cloud 公式 APT |
| `glow` | release-binary | GitHub Releases |
| `coscli` | release-binary | Tencent 公式 release binary |
| `awst` / `gcloudt` / `tcclit` | local-wrapper | `cloud-cli` リポジトリの bash wrapper |

### cloud-cli wrapper

`awst` / `gcloudt` / `tcclit` は外部配布 CLI ではなく、[cloud-cli](https://github.com/aktus-tk/cloud-cli) 内の wrapper です。

- デフォルト: `~/github/aktus-tk/cloud-cli`
- 変更: `CLOUD_CLI_REPO=/path/to/cloud-cli`
- 配置後、依存する native CLI（`aws` / `gcloud` / `tccli`）の存在を確認します

| Wrapper | 依存 |
|---|---|
| `awst` | `aws` |
| `gcloudt` | `gcloud` |
| `tcclit` | `tccli` |

## 認証情報について

このツールは認証情報を管理しません。`doctor` は設定の有無だけを表示し、値は表示しません。

## セキュリティ方針

- `curl | bash` は使いません（ダウンロードと実行を分離）
- 公式配布元のみを使用
- 公式チェックサムが公開されている場合は必ず検証
- root 権限は APT 導入時のみ（明示的に `sudo` を使用）
- トークンや認証情報はログへ出力しません

## テスト

```bash
bash tests/test.sh
```

オフラインで実行でき、実 `$HOME` の既存 CLI は変更しません（各テストは一時 `CLOUD_TOOLBOX_HOME` を使用）。
