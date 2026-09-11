# cli-toolbox

クラウド/運用CLIを、ユーザー領域へ冪等に導入するツールです。Terraform の `apply` のような振る舞いをします。

```bash
./cli-toolbox.sh install            # 標準セットを stable 最新版へ収束（インストール＋更新）
./cli-toolbox.sh install gh glow    # 指定したCLIだけ収束
./cli-toolbox.sh delete glow gcloud # cli-toolbox 管理分のみ削除
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

## 対応環境

| OS | アーキテクチャ | パッケージ管理 |
|---|---|---|
| Linux (Debian/Ubuntu) | amd64 / arm64 | APT (`gh`, `az`) |
| macOS | amd64 / arm64 (Intel / Apple Silicon) | Homebrew (`gh`, `az`, `aws`) |

- **gcloud** は Linux/macOS とも公式 archive（tar.gz）をユーザー領域へ展開します（APT/Homebrew 非依存）
- **uv / tccli** は全 OS で共通（`uv` standalone + `uv tool`）
- **Homebrew 自体は自動インストールしません**（未導入時は `requires-package-manager` を表示）
- OS 管理の既存 CLI（`/usr/bin`, Homebrew, snap 等）は削除・更新しません

## Python 製 CLI の管理方針

- **Python 製 CLI（`tccli`）は `uv tool` で隔離管理します**（`uv tool install --upgrade <pkg>`）。
- `pipx` は cli-toolbox の管理対象外です（インストールしません）。
- OS に `pipx` が既に入っていても、cli-toolbox は削除・上書きしません。`list` にも表示しません。
- `pip install --user`、グローバル `pip install`、独自 venv による新規導入は行いません。
- `uv` 自体は [公式 standalone installer](https://docs.astral.sh/uv/getting-started/installation/) で導入します（`curl | bash` は使わず、スクリプトをダウンロードしてから実行）。
- **AWS CLI v2**（Linux）は公式インストーラー、**macOS** は Homebrew を使用します。
- cli-toolbox 管理外の既存 CLI（system / pipx / pyenv など）は勝手に削除・更新しません。

### tccli の移行

既存の pip / pipx / pyenv 配下に `tccli` がある場合:

- `list` では `STATE=migration-available` を表示します。
- `install tccli` は `uv tool install --upgrade tccli` を実行します。
- `~/.local/bin` が PATH 上で既存 `tccli` より優先されることを確認し、衝突時は警告します。
- 既存環境のアンインストールは行いません。

## セットアップ

```bash
git clone https://github.com/aktus-tk/cli-toolbox ~/github/aktus-tk/cli-toolbox
cd ~/github/aktus-tk/cli-toolbox

./cli-toolbox.sh install

# または PATH へ追加
export PATH="$HOME/github/aktus-tk/cli-toolbox:$PATH"
cli-toolbox.sh install
```

導入先はデフォルトで `~/.cli-toolbox` です。`CLI_TOOLBOX_HOME` で変更できます。

旧名 `~/.cloud-toolbox` / `CLOUD_TOOLBOX_*` から移行する場合は、ディレクトリをリネームするか再インストールしてください。

```bash
mv ~/.cloud-toolbox ~/.cli-toolbox   # 既存の導入を引き継ぐ場合
```

```text
~/.cli-toolbox/
├── bin/       # 導入されたCLIバイナリ/シンボリックリンク（PATHに追加）
├── state/     # manifest（cli-toolbox が記録した管理方式・バージョン）
└── tools/     # 展開されたツールツリー（aws-cli, google-cloud-sdk など）
```

`gcloud` の配置例:

```text
~/.cli-toolbox/
├── bin/gcloud -> ../tools/google-cloud-sdk/current/bin/gcloud
└── tools/google-cloud-sdk/
    ├── versions/<version>/
    └── current -> versions/<version>
```

`tccli`（uv tool）は `~/.local/bin` に配置されます。`UV_TOOL_BIN_DIR` で変更できます。

## PATH 設定

Linux:

```bash
export PATH="$HOME/.cli-toolbox/bin:$HOME/.local/bin:$HOME/bin:$PATH"
```

macOS:

```bash
export PATH="$HOME/.cli-toolbox/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH"
```

`.bashrc` / `.zshrc` などへ追記してください（このツールは自動では編集しません）。`doctor` で不足と追加例を表示します。

## 使い方

```bash
./cli-toolbox.sh install
./cli-toolbox.sh install tccli aws
./cli-toolbox.sh delete glow gcloud
./cli-toolbox.sh doctor
./cli-toolbox.sh list
./cli-toolbox.sh list tccli aws
./cli-toolbox.sh help
```

### delete

`delete`（`remove` / `uninstall` も同義）は **cli-toolbox が導入した成果物だけ** を削除します。

- `~/.cli-toolbox/bin` のバイナリ / symlink
- `~/.cli-toolbox/tools/` 配下（`aws-cli`, `google-cloud-sdk` など）
- `uv tool` で入れた `tccli`
- manifest の記録

削除しません:

- APT / Homebrew で入れた system パッケージ本体（manifest は消し、手動削除コマンドを表示）
- OS 管理の既存 CLI
- 認証設定（`~/.aws`, `~/.config/gcloud` など）

```bash
./cli-toolbox.sh delete gcloud tccli
```

## list の見方

| 列 | 意味 |
|---|---|
| STATUS | `managed` / `system` / `missing` / `requires-root` / `requires-package-manager` / `unsupported` |
| PROVIDER | `uv-tool` / `official-installer` / `official-archive` / `apt` / `brew` / `release-binary` / `local-wrapper` / `system-package` / `unknown` |
| STATE | `unchanged` / `update-available` / `install-required` / `migration-available` / `unknown` |

例:

```text
CLI      STATUS   CURRENT   LATEST   PATH                         PROVIDER
tccli    managed  3.1...    3.1...   ~/.local/bin/tccli           uv-tool
gcloud   managed  502...    502...   ~/.cli-toolbox/bin/gcloud  official-archive
gh       system   2.x       2.x      /usr/bin/gh                  system-package
az       missing  -         2.77.0   -                            apt
```

`requires-root` は Linux APT 導入に `sudo` が必要な状態です。`requires-package-manager` は macOS で Homebrew が未導入の状態です。

## 標準セット

```bash
uv gh glow coscli tccli aws gcloud az
```

## CLI ごとの管理方式（provider 選択表）

| CLI | Linux | macOS |
|---|---|---|
| `uv` | official-installer | official-installer |
| `tccli` | uv-tool | uv-tool |
| `aws` | official-installer | brew |
| `gh` | apt | brew |
| `gcloud` | official-archive | official-archive |
| `az` | apt | brew |
| `glow` | release-binary | brew（未導入時は release-binary） |
| `coscli` | release-binary | release-binary |
| `awst` / `gcloudt` / `tcclit` | local-wrapper | local-wrapper |

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
- root 権限は Linux APT 導入時のみ（明示的に `sudo` を使用）
- トークンや認証情報はログへ出力しません
- gcloud archive 展開時はパストラバーサルを検査します

## テスト

```bash
bash tests/test.sh
```

オフラインで実行でき、実 `$HOME` の既存 CLI は変更しません（各テストは一時 `CLI_TOOLBOX_HOME` を使用）。OS / package manager は mock 可能です。
