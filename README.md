# cli-toolbox

クラウド/運用CLIを、ユーザー領域へ冪等に導入するツールです。Terraform の `apply` のような振る舞いをします。

```bash
./cli-toolbox.sh install            # targets.txt の CLI を stable 最新版へ収束
./cli-toolbox.sh install aws codex  # 指定した CLI だけ収束
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
| Linux (Debian/Ubuntu) | amd64 / arm64 | APT (`gh`, `az`, `terraform`) |
| macOS | amd64 / arm64 (Intel / Apple Silicon) | Homebrew (`gh`, `az`, `aws`, `terraform`) |

- **gcloud** は Linux/macOS とも公式 archive（tar.gz）をユーザー領域へ展開します（APT/Homebrew 非依存）
- **uv / tccli** は全 OS で共通（`uv` standalone + `uv tool`）
- **Homebrew 自体は自動インストールしません**（未導入時は `requires-package-manager` を表示）
- OS 管理の既存 CLI（`/usr/bin`, Homebrew, snap 等）は削除・更新しません

## Python 製 CLI の管理方針

- **Python 製 CLI（`tccli`）は `uv tool` で隔離管理します**（`uv tool install --upgrade <pkg>`）。
- `pipx` は cli-toolbox の管理対象外です（インストールしません）。
- OS に `pipx` が既に入っていても、cli-toolbox は削除・上書きしません。`list` にも表示しません。
- `pip install --user`、グローバル `pip install`、独自 venv による新規導入は行いません。
- `uv` 自体は [公式 standalone installer](https://docs.astral.sh/uv/getting-started/installation/) で導入します（公式ドメインからスクリプトをダウンロードしてから実行。`curl | bash` のようなパイプ実行はしません）。
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

導入先は `~/.cli-toolbox` です。

旧名 `~/.cloud-toolbox` から移行する場合は、ディレクトリをリネームするか再インストールしてください。

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

`tccli`（uv tool）は `~/.local/bin` に配置されます。

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
./cli-toolbox.sh install tccli aws glow
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
| PROVIDER | 主に `uv-tool` / `official-installer` / `official-archive` / `apt` / `brew` / `release-binary` / `system-package` / `unknown`（既存環境では `pipx` 等も表示される場合あり） |
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

## targets.txt と optional

引数なしの `install` / `list` / `doctor` は、リポジトリ直下の `targets.txt` を使います。

```text
# Standard CLIs
uv
gh
rg
glow
mlr
aws
gcloud
tccli
terraform

# Optional CLIs (uncomment to add to default install, or install explicitly)
# az
# coscli
# granted
# saml2aws
# oci
# kubectl
# helm

# AI agents (optional)
# opencode
# agent       # Cursor Agent CLI
# codebuddy
# claude
# codex
# agy
```

- 1行1CLI、空行と `#` 行頭コメントを無視、行末 `# コメント` を除去
- `targets.txt` から外した CLI は自動削除されません（`delete` で明示削除）

`SUPPORTED_CLIS` に含まれるが `targets.txt` に無い CLI（明示指定でインストール）:

```bash
az coscli granted saml2aws oci kubectl helm opencode agent codebuddy claude codex agy
```

## CLI の説明（標準 / 任意）

- **標準**: `targets.txt` に含まれ、引数なしの `install` / `list` / `doctor` の対象。
- **任意**: `SUPPORTED_CLIS` に含まれるが `targets.txt` に無い CLI。`install <name>` で明示指定する。

| 区分 | 種別 | CLI | 理由 |
|---|---|---|---|
| 標準 | CLIツール | `uv` | Python製CLIの実行基盤（`uv tool`で`tccli`等を隔離） |
| 標準 | CLIツール | `gh` | GitHub操作 |
| 標準 | CLIツール | `rg` | 高速ファイル検索（ripgrep）が必要なときだけ |
| 標準 | CLIツール | `glow` | 人間がMarkdownを端末表示するときだけ |
| 標準 | CLIツール | `mlr` | CSV・JSONなどのデータ整形（Miller）が必要なときだけ |
| 標準 | Cloud CLI | `aws` | AWS操作 |
| 標準 | Cloud CLI | `gcloud` | GCP操作 |
| 標準 | Cloud CLI | `tccli` | Tencent Cloud操作 |
| 任意 | Cloud CLI | `granted` | AWSロール/SSOアクセス（Granted） |
| 任意 | Cloud CLI | `saml2aws` | SAML IdP 経由の AWS 一時認証情報 |
| 任意 | Cloud CLI | `az` | Azure操作 |
| 任意 | Cloud CLI | `coscli` | COSへ直接ファイル転送するときだけ |
| 任意 | Cloud CLI | `oci` | Oracle Cloud操作（`targets.txt`ではコメントアウト中） |
| 標準 | IaC | `terraform` | IaC調査・変更・検証 |
| 任意 | Kubernetes | `kubectl` | Kubernetes操作 |
| 任意 | Kubernetes | `helm` | Kubernetesへのアプリ配布 |
| 任意 | AI Agent | `opencode` | AIエージェントCLI（OpenCode） |
| 任意 | AI Agent | `agent` | AIエージェントCLI（Cursor Agent CLI） |
| 任意 | AI Agent | `codebuddy` | AIエージェントCLI（CodeBuddy） |
| 任意 | AI Agent | `claude` | AIエージェントCLI（Claude Code） |
| 任意 | AI Agent | `codex` | AIエージェントCLI（Codex） |
| 任意 | AI Agent | `agy` | AIエージェントCLI（Antigravity） |

## CLI ごとの管理方式（provider 選択表）

| CLI | Linux | macOS |
|---|---|---|
| `uv` | official-installer | official-installer |
| `tccli` | uv-tool | uv-tool |
| `aws` | official-installer | brew |
| `granted` | release-binary | brew |
| `saml2aws` | release-binary | brew（未導入時は release-binary） |
| `gh` | apt | brew |
| `gcloud` | official-archive | official-archive |
| `az` | apt | brew |
| `terraform` | apt (HashiCorp) | brew (`hashicorp/tap`) |
| `kubectl` | release-binary | release-binary |
| `helm` | release-binary | release-binary |
| `oci` | official-installer | brew（未導入時は official-installer） |
| `glow` | release-binary | brew（未導入時は release-binary） |
| `coscli` | release-binary | release-binary |
| `rg` | release-binary | brew（未導入時は release-binary） |
| `mlr` | release-binary | brew（未導入時は release-binary） |
| `opencode` | release-binary | brew（未導入時は release-binary） |
| `agent` (Cursor Agent CLI) | official-installer | official-installer |
| `codebuddy` | official-installer / brew | brew（未導入時は official-installer） |
| `claude` | official-installer | official-installer |
| `codex` | official-installer | official-installer |
| `agy` | official-installer | official-installer |

## 組み合わせ可能な関連ツール

- [cloud-cli](https://github.com/aktus-tk/cloud-cli) — `aws` / `gcloud` / `tccli` の人間向けラッパー（`awst` / `gcloudt` / `tcclit`）。独立したリポジトリで運用され、cli-toolbox の管理対象外です。

## 認証情報について

このツールは認証情報を管理しません。`doctor` は設定の有無だけを表示し、値は表示しません。

## セキュリティ方針

- 未確認のスクリプトを `curl | bash` で直接実行しません
- 公式提供元が標準のインストール方法として案内しているインストーラー（例: Claude Code）は、公式ドメインから取得したうえで使用します（ダウンロードと実行を分離）
- 公式配布元のみを使用
- 公式チェックサムが公開されている場合は必ず検証
- root 権限は Linux APT 導入時のみ（明示的に `sudo` を使用）
- トークンや認証情報はログへ出力しません
- gcloud archive 展開時はパストラバーサルを検査します

## テスト

```bash
bash tests/test.sh
```

オフラインで実行でき、実 `$HOME` の既存 CLI は変更しません。OS / package manager は mock 可能です。
