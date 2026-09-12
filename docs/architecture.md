# Architecture

cli-toolbox は、複数の CLI を Linux/macOS のユーザー環境へ冪等に導入・更新する bootstrapper です。Terraform の `apply` のように、実行のたびに stable 最新版へ状態を収束させます。

## ディレクトリ構成

```text
targets.txt             # デフォルトの install/list/doctor 対象（利用者が編集）
cli-toolbox.sh          # エントリポイント（コマンド dispatch）
lib/
├── common.sh           # 共通ユーティリティ
├── packages.sh         # apt / brew 抽象化
├── providers.sh        # CLI メタデータ・状態判定・list
├── targets.sh          # targets.txt の読み込み
└── installers.sh       # install / delete の実体
tests/
└── test.sh             # オフラインテスト
docs/
├── adding-cli.md       # CLI 追加・削除チェックリスト
└── architecture.md     # 本ドキュメント
```

`source` の依存順は `common → packages → providers → targets → installers` です。

## レイヤ構成

```text
cli-toolbox.sh
    │
    ├── lib/common.sh       … 共通ユーティリティ
    ├── lib/packages.sh     … apt / brew 抽象化
    ├── lib/providers.sh    … CLI メタデータ・状態判定・list
    └── lib/installers.sh   … install / delete の実体
```

各レイヤの責務:

| レイヤ | ファイル | 責務 |
|---|---|---|
| Entry | `cli-toolbox.sh` | サブコマンド dispatch、doctor、利用者向け出力 |
| Common | `lib/common.sh` | ログ、DL、checksum、archive、atomic install、PATH 解決 |
| Packages | `lib/packages.sh` | APT / Homebrew の install・version・repo 設定 |
| Providers | `lib/providers.sh` | CLI 一覧、provider 解決、manifest、list 状態判定 |
| Installers | `lib/installers.sh` | CLI ごとの install / delete 実装 |

## `cli-toolbox.sh` — エントリポイント

ユーザーが実行する本体です。サブコマンドを振り分けます。

| コマンド | 関数 | 役割 |
|---|---|---|
| `install` | `cmd_install` | CLI を stable 最新版へ収束。引数なしなら `targets.txt` |
| `delete` | `cmd_delete` | cli-toolbox 管理分だけ削除 |
| `doctor` | `cmd_doctor` | OS / PATH / 標準セット CLI の健康診断 |
| `list` | `cmd_list` | 状態テーブル出力 |
| `help` | `usage` | ヘルプ表示 |

`doctor` 固有の処理:

- `doctor_one` — 各 CLI の PATH・実行可否・バージョン確認
- `doctor_config` — 認証設定の有無だけ確認（値は出さない）

出力の約束:

- **stdout**: 機械可読な結果行・テーブル（`install` の `installed` / `unchanged` 行、`list` の表など）
- **stderr**: ログ・警告・エラー（`log_info`, `log_warn`, `log_error`）

## `lib/common.sh` — 共通基盤

どの層からも使う低レベル関数です。テストで関数を差し替え可能にしています。

| グループ | 代表関数 | 内容 |
|---|---|---|
| ログ | `log_info`, `log_warn`, `log_error` | stderr 出力 |
| プラットフォーム | `detect_platform` | `TB_OS` (linux/darwin) / `TB_ARCH` (amd64/arm64) を設定 |
| バージョン | `_parse_version`, `version_gt` | CLI ごとの版取得・比較 |
| ダウンロード | `http_get`, `download_file` | curl ベース（`CLI_TOOLBOX_CURL` で差し替え可） |
| GitHub API | `github_release_json`, `github_asset_url` | jq なしで JSON 解析 |
| PyPI | `get_latest_version_pypi` | `tccli` 用 |
| チェックサム | `verify_sha256`, `checksum_for` | 公式 hash 検証 |
| archive | `extract_archive`, `_archive_entries_safe` | 展開前のパストラバーサル検査 |
| インストール | `atomic_install`, `atomic_symlink` | 失敗時に旧版を残す |
| PATH | `resolve_path`, `is_managed` | 実際に使われるバイナリの解決 |
| 一時ディレクトリ | `make_tempdir`, `cleanup` | EXIT 時に自動削除 |

`CLI_TOOLBOX_HOME`（デフォルト `~/.cli-toolbox`）もここで初期化します。

## `lib/packages.sh` — パッケージマネージャ層

APT / Homebrew だけを扱います。全 OS 共通のパッケージマネージャではありません。

| 関数 | 役割 |
|---|---|
| `cli_package_name` | CLI 名 → apt/brew パッケージ名（例: `rg` → `ripgrep`） |
| `has_apt`, `has_brew`, `can_sudo` | 利用可否・sudo 可否 |
| `apt_setup_repo_*`, `apt_ensure_repo` | `gh` / `az` / `terraform` の apt リポジトリ設定 |
| `apt_update_quiet` | 対象 CLI の repo だけ更新 |
| `brew_install_or_upgrade` | `terraform` は `hashicorp/tap` を tap |
| `package_installed_version` 等 | provider 共通 API |

## `lib/providers.sh` — メタデータ・状態判定層

「どの CLI を」「どう入れるか」「今どういう状態か」を担当します。

### CLI セット

| 定義 | 内容 |
|---|---|
| `targets.txt` | 引数なし `install` / `list` / `doctor` の対象 |
| `SUPPORTED_CLIS` | cli-toolbox が対応する全 CLI |
| `manifest.tsv` | cli-toolbox が実際に導入した CLI の内部記録 |

`targets.txt` から外しても自動削除しません。manifest は `targets.txt` から再生成しません。

### 主な関数

| グループ | 代表関数 | 内容 |
|---|---|---|
| provider 解決 | `resolve_provider`, `cli_preferred_provider` | OS 別のインストール方式 |
| manifest | `manifest_record`, `manifest_lookup`, `manifest_remove` | `~/.cli-toolbox/state/manifest.tsv` |
| 所有権 | `cli_is_toolbox_managed`, `classify_path_provider` | managed / system / pipx 等の判定 |
| uv tool | `uv_tool_executable_path`, `uv_tool_has` | `tccli` 管理 |
| gcloud | `gcloud_archive_url`, `gcloud_latest_version` | 公式 archive 用 |
| list | `inspect_cli`, `list_latest_version`, `print_list_table` | `list` コマンドの出力生成 |

### `list` の列

| 列 | 意味 | 例 |
|---|---|---|
| STATUS | 導入状態の大分類 | `managed`, `system`, `missing`, `requires-root`, `requires-package-manager`, `unsupported` |
| PROVIDER | 管理方式 | `apt`, `brew`, `release-binary`, `uv-tool`, `official-archive`, `system-package`, `unknown` |
| STATE | 更新要否 | `unchanged`, `update-available`, `install-required`, `migration-available`, `unknown` |

`STATUS=managed` は manifest に cli-toolbox が導入した記録がある場合だけ使います。`~/.cli-toolbox` 内にあるだけでは推測しません。

### provider 一覧

CLI とインストール方式は分離します。利用可能な provider:

- `apt`, `brew`, `brew-cask`
- `uv-tool`, `official-installer`, `official-archive`
- `release-binary`
- `system-package`, `unknown`

## `lib/targets.sh` — targets.txt 読み込み

| 関数 | 内容 |
|---|---|
| `targets_file_path` | リポジトリルートの `targets.txt` のパス（`${TB_ROOT}/targets.txt`） |
| `_normalize_target_line` | コメント・空白の除去 |
| `load_targets` | `TB_TARGETS` 配列へ読み込み（重複除去・未知名はエラー） |
| `resolve_command_clis` | 引数なし時は targets、あり時は指定 CLI |
| `validate_cli_names` | `SUPPORTED_CLIS` との照合 |

## `lib/installers.sh` — インストール実体

CLI ごとの install / delete ロジックです。

| グループ | 関数 | 内容 |
|---|---|---|
| 共通 | `_installer_start`, `_finish_install` | 結果を `TB_STATE` / `TB_DETAIL` に格納 |
| uv / tccli | `install_uv`, `install_tccli` | standalone + `uv tool` |
| apt/brew | `install_package_cli`, `install_gh` 等 | パッケージマネージャ経由 |
| gcloud | `install_gcloud` | 公式 tar.gz を `tools/` に展開 |
| GitHub release | `install_glow`, `install_rg`, `install_mlr` 等 | バイナリ + checksum 検証 |
| aws | `install_aws` | Linux: 公式 installer / macOS: brew |
| delete | `_delete_*`, `run_uninstaller` | 管理分のみ削除 |
| dispatch | `run_installer`, `run_uninstaller` | CLI 名から関数を振り分け |

`install` の出力例:

```text
rg         installed  15.0.0
tccli      unchanged  3.1.165.1
```

`TB_STATE` の値: `installed`, `updated`, `unchanged`, `deleted`, `skipped-not-managed`, `skipped-system`, `error`

## ファイルシステム配置

```text
~/.cli-toolbox/
├── bin/       # 導入された CLI バイナリ / symlink（PATH に追加）
├── state/     # manifest（管理方式・バージョン・path の記録）
│   └── manifest.tsv
└── tools/     # 展開されたツールツリー（aws-cli, google-cloud-sdk など）
```

`tccli`（uv tool）は `~/.local/bin` に配置されます。

manifest の形式（TSV）:

```text
<cli>    <provider>    <version>    <path>
```

## 実行フロー

### `install rg` の例

```text
cli-toolbox.sh
  └─ cmd_install
       └─ run_installer rg              (installers.sh)
            └─ install_rg
                 ├─ resolve_provider rg linux   (providers.sh)
                 ├─ github_release_json         (common.sh)
                 ├─ verify_sha256               (common.sh)
                 ├─ atomic_install              (common.sh)
                 └─ manifest_record             (providers.sh)
```

### `list rg` の例

```text
cli-toolbox.sh
  └─ cmd_list
       └─ inspect_cli rg              (providers.sh)
            ├─ resolve_provider
            ├─ get_installed_version
            └─ list_latest_version
```

### `delete gcloud` の例

```text
cli-toolbox.sh
  └─ cmd_delete
       └─ run_uninstaller gcloud
            └─ _delete_gcloud
                 ├─ cli_is_toolbox_managed
                 ├─ _remove_bin_link
                 ├─ rm -rf tools/google-cloud-sdk
                 └─ manifest_remove
```

## `tests/test.sh` — テストスイート

ネットワークや実 `$HOME` に依存しないオフラインテストです。

| 要素 | 内容 |
|---|---|
| `source_libs` | lib を直接 source（関数単体テスト用） |
| `cli` | `cli-toolbox.sh` を subprocess 実行 |
| `make_*_fixture` | GitHub API / PyPI / archive のモックデータ |
| `assert_*` | 期待値チェック |

テストでは一時ディレクトリへ `CLI_TOOLBOX_HOME` を向け、`http_get` や `has_apt` を差し替えて動作を確認します。実環境の既存 CLI は変更しません。

## 内部向け環境変数（利用者ヘルプには非掲載）

通常利用者は `targets.txt` とサブコマンドだけで運用します。以下はテスト・特殊用途・内部実装向けの差し替え口です。

| 変数 | 用途 | デフォルト |
|---|---|---|
| `CLI_TOOLBOX_HOME` | 導入ルート（manifest / bin / tools） | `~/.cli-toolbox` |
| `CLI_TOOLBOX_API_BASE` | GitHub API ベース URL | `https://api.github.com` |
| `CLI_TOOLBOX_PYPI_BASE` | PyPI JSON ベース URL | `https://pypi.org` |
| `CLI_TOOLBOX_UV_INSTALL_URL` | uv standalone installer URL | `https://astral.sh/uv/install.sh` |
| `CLI_TOOLBOX_CURL` | `curl` コマンド差し替え（テスト用） | `curl` |

`UV_TOOL_BIN_DIR` と `GITHUB_TOKEN` は uv / GitHub の標準環境変数です。cli-toolbox はそれぞれ `tccli` の配置先と GitHub API のレート制限回避に利用しますが、利用者向けヘルプには記載しません。

`targets.txt` のパスはリポジトリルート固定です（`CLI_TOOLBOX_TARGETS` は廃止）。テストで別内容の `targets.txt` を使う場合は、`cli-toolbox.sh` と `lib/` を含むサンドボックスディレクトリを用意します。

## 関連ドキュメント

| ファイル | 対象 |
|---|---|
| [README.md](../README.md) | 利用者向けの使い方・セット構成 |
| [AGENTS.md](../AGENTS.md) | AI Agent 向けの不変条件・安全規則 |
| [adding-cli.md](adding-cli.md) | CLI 追加・削除のチェックリスト |
