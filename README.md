# cli-toolbox

クラウド/運用CLIを、ユーザー領域へ冪等に導入するツールです。Terraform の `apply` のような振る舞いをします。

```bash
cli-toolbox install            # 標準セットを stable 最新版へ収束（インストール＋更新）
cli-toolbox install gh glow    # 指定したCLIだけ収束
cli-toolbox doctor             # 環境と導入済みCLIの健康診断
cli-toolbox list               # 各CLIの状態一覧
```

- 実行のたびに公式の stable 最新版を確認し、状態を収束させます。
  - 未導入 → インストール
  - 古い → stable 最新版へ更新
  - stable 最新版 → 何もしない
  - 失敗 → 既存の正常なバイナリを保持
  - 管理対象外のCLI → 削除しない
- `update` コマンドはありません。`install` がインストールと更新の両方を担当します。
- Docker/Podman は使いません。シェル設定ファイルも変更しません。

## 対応環境

- Linux amd64 / Linux arm64（主対象）
- macOS は設計上考慮していますが、現時点では未対応です（`install` はエラーになります）

## セットアップ

```bash
# リポジトリを取得して PATH へ追加
git clone <このリポジトリ> ~/github/aktus-tk/cli-toolbox
export PATH="$HOME/github/aktus-tk/cli-toolbox:$PATH"
```

導入先はデフォルトで `~/.cloud-toolbox` です。`CLOUD_TOOLBOX_HOME` で変更できます。

```text
~/.cloud-toolbox/
├── bin/       # 導入されたCLIバイナリ/シンボリックリンク（PATHに追加）
├── lib/       # 予約
├── tools/     # 展開されたツールツリー（aws-cli, google-cloud-sdk など）
└── python/    # CLIごとの venv
```

## PATH 設定

`install` 後に CLI を使えるようにするため、`~/.cloud-toolbox/bin` を PATH へ追加します。

```bash
export PATH="$HOME/.cloud-toolbox/bin:$HOME/bin:$HOME/.local/bin:$PATH"
```

`.bashrc` / `.zshrc` などへ追記してください（このツールは自動では編集しません）。

## 使い方

```bash
cli-toolbox install            # 標準セットを収束
cli-toolbox install gh glow    # 指定CLIのみ収束
cli-toolbox doctor             # 環境診断（PATH、導入状態、バージョン、設定有無など）
cli-toolbox list               # 状態一覧（CLI / status / current / latest / path / state）
cli-toolbox list gh aws        # 指定CLIのみ一覧
cli-toolbox help
```

`install` は更新も兼ねます。再実行するたびに公式 stable 最新版へ収束します。

実行例：

```text
gh       installed  2.80.0
glow     updated    2.1.0 -> 2.1.1
coscli   unchanged  1.0.9

Apply complete: 1 installed, 1 updated, 1 unchanged, 0 failed
```

一部が失敗した場合は、最後に失敗対象をまとめて表示し、終了コードは非0になります。

## 標準セット

引数なしの `install` で導入されるCLIです。`lib/installers.sh` の `STANDARD_SET` 配列で簡単に変更できます。

```bash
STANDARD_SET=(gh glow coscli uv tccli pipx aws gcloud)
```

## 対応CLI一覧と導入方式

| CLI | 配布元 | 導入方式 | チェックサム |
|---|---|---|---|
| `gh` (GitHub CLI) | GitHub Releases (cli/cli) | tar.gz からバイナリを展開し `bin/` へ原子配置 | `gh_<V>_checksums.txt` で検証 |
| `glow` | GitHub Releases (charmbracelet/glow) | tar.gz からバイナリを展開 | `checksums.txt` で検証 |
| `coscli` | GitHub Releases (tencentyun/coscli) | 生バイナリを `bin/` へ原子配置 | `sha256sum.log` で検証 |
| `uv` | GitHub Releases (astral-sh/uv) | tar.gz から `uv` と `uvx` を導入 | `.sha256` サイドカーで検証 |
| `tccli` | PyPI | 専用 venv + wheel (`pip install --no-index`) | PyPI JSON の sha256 で検証 |
| `pipx` | PyPI | 専用 venv + wheel (`pip install --no-index`) | PyPI JSON の sha256 で検証 |
| `aws` (AWS CLI v2) | AWS公式 zip | 公式ユーザー空間インストーラを実行 (`--update`) | 公式sha256無し（PGPのみ）→ **警告のみ**で続行 |
| `gcloud` | Google公式 tar.gz | `tools/` へ展開し `bin/gcloud` をシンボリックリンク | 機械可読なsha256無し → **警告のみ**で続行 |

> 既知の逸脱: `gcloud` の最新版検出は `rapid` チャンネルの `components-2.json` を使用します。これは機械可読なマニフェストを配布している唯一のチャンネルです（`stable` / `release` エンドポイントは404を返すため利用できません）。

Python系CLI（`tccli`, `pipx`）は `python3 -m venv` で `$CLOUD_TOOLBOX_HOME/python/<name>` に venv を作成し、公式PyPIのwheel（対象バージョンの正確な wheel をPyPI JSONから特定）をsha256検証後に `pip install --upgrade` で導入します。

> 注意: プライマリの wheel 自体は sha256 検証しますが、pip が依存解決で取得する依存パッケージは個別にチェックサム検証されません（PyPIの公式配布物をそのまま使用）。依存パッケージも厳密に検証したい場合は、今後の改善課題です。

## 認証情報について

このツールは認証情報を管理しません。取得・設定・表示もしません。`doctor` は「設定の有無」だけを表示し、値は表示しません。

- GitHub API の rate limit に達した場合はエラーメッセージを表示します。`GITHUB_TOKEN` を設定すると上限を上げられます（値は表示されません）。

## doctor の見方

各項目を `OK` / `WARN` / `ERROR` で表示します。

- OSとアーキテクチャ
- `$CLOUD_TOOLBOX_HOME/bin` が PATH に含まれるか（不足時は追加すべき export 行を表示）
- 各CLIの実体パス、実行可否、バージョン
- PATH上で別の同名CLIが導入済みの管理対象CLIより優先されている場合（shadowing）は WARN
- `bin/` の壊れたシンボリックリンク
- 必要なランタイム（Python系CLIは `python3`）
- 設定ファイル/環境変数の有無（`gh auth` / `AWS_PROFILE` や `~/.aws` / gcloud設定や `CLOUDSDK_CONFIG` / tccli設定や `TENCENTCLOUD_*` など）

`ERROR` がある場合のみ終了コードが非0になります。

## アンインストール

導入物は `$CLOUD_TOOLBOX_HOME` 配下にすべて収まっています。ディレクトリ削除で完結します。

```bash
# 削除前に、実際のパスが本当に ~/.cloud-toolbox であることを必ず確認してください
echo "$CLOUD_TOOLBOX_HOME"     # 未設定なら ~/.cloud-toolbox
rm -r "$HOME/.cloud-toolbox"
```

PATH へ追加した行を `.bashrc` / `.zshrc` から削除してください。

## 制約と未対応事項

| CLI | 状態 | 理由 |
|---|---|---|
| `az` | 未対応 | root不要の自己完結バイナリが無い（pipx/venv方式のみ）。導入容量が約1GB。配布tar.gzはPython 3.14を要求するため、現行環境では無理なく導入できる方式が無い |
| `awst`, `gcloudt`, `tcclit` | 未対応 | 配布元リポジトリ（cloud-cli）にGitHub Releaseバイナリが無い。これらはbashラッパーで、ネイティブCLI（aws / gcloud / tccli）と `tc-assume` を必要とする |

`install` に未対応CLIを明示指定すると `unsupported` として表示され、失敗としてカウントされます（終了コード非0）。実装は行いません。

## 新しいCLIを追加する方法

1. `lib/installers.sh` に `install_<name>` 関数を追加する
   - `detect_platform` → 最新版取得 → 導入済みバージョン比較 → ダウンロード → チェックサム検証（あれば） → 展開/原子配置 → バージョン再確認
   - 結果は `TB_STATE`（installed / updated / unchanged / error）と `TB_DETAIL` に設定する
2. `run_installer` の `case` に分岐を追加する
3. `SUPPORTED_CLIS` と必要なら `STANDARD_SET` に名前を追加する
4. `_parse_version` にバージョン出力のパースを追加する（`doctor` / `list` / 収束判定で使用）
5. `tests/test.sh` にfixtureを追加してテストする

共通処理（ダウンロード、チェックサム、展開、原子配置など）は `lib/common.sh` にあります。CLIごとのmanifest化は、対応CLIが増えて重複が明確になった時点で検討します。

## セキュリティ方針

- `curl | bash` は使いません（ダウンロードと実行を分離）
- `mktemp -d` による一時ディレクトリを使用し、終了時に削除
- 公式配布元のみを使用
- 公式チェックサムが公開されている場合は必ず検証
- バイナリは一時ファイル経由で原子配置（`mv -f`）。失敗時は既存バイナリを保持
- root権限・`sudo` は使用しません
- アーカイブ展開時はパストラバーサル（`..` / 絶対パス）を拒否
- トークンや認証情報はログへ出力しません
- 取得URLとバージョンは表示します

## テスト

```bash
bash tests/test.sh
```

オフラインで実行でき、実 `$HOME` には一切触れません（各テストは一時ディレクトリを `CLOUD_TOOLBOX_HOME` にします）。GitHub API・PyPI・ダウンロードは `file://` fixture とモックcurlで代替されます。