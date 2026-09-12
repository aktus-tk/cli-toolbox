# CLIの追加・削除

実装の更新箇所は `targets.txt`（デフォルト導入対象に含める場合）、`lib/providers.sh`、`lib/installers.sh`、`lib/common.sh`、`lib/packages.sh`、`lib/targets.sh`、`cli-toolbox.sh`、`tests/test.sh`、`README.md` です。

## 追加

- [ ] CLI名と実行ファイル名を決めた
- [ ] `SUPPORTED_CLIS`（`lib/providers.sh`）へ追加した
- [ ] デフォルト導入対象に含める場合は `targets.txt` へ追加した
- [ ] `resolve_provider`（`lib/providers.sh`）で Linux/macOS の provider を定義した
- [ ] amd64/arm64 の配布物を確認した
- [ ] `list_latest_version` / `list_repo`（`lib/providers.sh`）で stable 最新版の取得を実装した
- [ ] `_parse_version`（`lib/common.sh`）で version parser を実装した
- [ ] 公式 checksum がある場合は installer で検証した
- [ ] `install_<cli>` と `run_installer`（`lib/installers.sh`）で atomic install/update を実装した
- [ ] `manifest_record` で実際の provider と path を記録した
- [ ] `inspect_cli`（`lib/providers.sh`）の list 表示が正しいことを確認した
- [ ] 必要なら `doctor_config`（`cli-toolbox.sh`）へ設定存在チェックを追加した
- [ ] `run_uninstaller`（`lib/installers.sh`）で delete を実装した
- [ ] apt/brew を使う場合は `cli_package_name` / `apt_ensure_repo`（`lib/packages.sh`）を更新した
- [ ] 失敗時に旧版が残ることを確認した
- [ ] system 版を削除しないことを確認した
- [ ] `tests/test.sh` に offline test を追加した
- [ ] README の一覧と provider 表を更新した

## 削除

- [ ] `targets.txt` から外した（該当する場合）
- [ ] `SUPPORTED_CLIS` から外すか supported のまま残すかを決めた
- [ ] 既存利用者への影響を確認した
- [ ] cli-toolbox 管理物だけ削除する（`run_uninstaller` / `cli_is_toolbox_managed`）
- [ ] system / 認証設定 / cache を削除しない
- [ ] manifest の扱いを決めた（`manifest_remove`）
- [ ] README とテストを更新した

## 分類の目安

- **targets.txt**: 引数なし `install` / `list` / `doctor` の対象。利用者が日常的に収束させたい CLI。
- **supported only**: `SUPPORTED_CLIS` にあるが `targets.txt` に無い CLI。`install <name>` で明示指定（例: `az`, `coscli`, `oci`, `kubectl`, `helm`）。
- `targets.txt` からコメントアウトしても自動削除しない。削除は `delete` / `remove` / `uninstall` のみ。
- RHEMS 固有の CLI（例: `tc-assume`）は個人版リポジトリへ追加しない。
