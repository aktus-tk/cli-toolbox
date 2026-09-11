# targets.txt 導入と AI エージェント CLI 追加（report）

日付: 2026-09-11

## 背景

cli-toolbox の導入対象はコード内の `STANDARD_SET` 配列で固定されており、利用者が「何を収束させるか」をリポジトリ外から変更できなかった。一方で、クラウド/運用 CLI に加え、AI エージェント CLI（`opencode`, `agent`, `claude` など）を同じ bootstrapper で管理したい要求があった。

この変更では、導入対象の宣言を `targets.txt` に移し、AI エージェント CLI を `SUPPORTED_CLIS` と既存の provider/install 基盤へ統合した。

## 変更前

| 項目 | 状態 |
|---|---|
| デフォルト導入対象 | `lib/providers.sh` の `STANDARD_SET`（`uv gh tccli aws gcloud az terraform`） |
| 引数なし `install` | `STANDARD_SET` を収束 |
| 引数なし `list` | `SUPPORTED_CLIS` 全件を表示 |
| 引数なし `doctor` | `STANDARD_SET` を診断 |
| AI エージェント CLI | 未対応 |
| 導入記録 | `~/.cli-toolbox/state/manifest.tsv`（provider / version / path） |

optional CLI（`glow`, `coscli`, `rg`, `mlr`, wrapper 系）は `SUPPORTED_CLIS` にあるが標準セット外で、`install <name>` の明示指定が必要だった。

## 検討した選択肢

### 導入対象の定義場所

| 案 | 概要 | 不採用理由 |
|---|---|---|
| A. `STANDARD_SET` を維持 | コード変更のみで標準セットを更新 | 利用者がリポジトリを fork/編集しないと対象を変えられない |
| B. `targets.txt`（採用） | リポジトリ直下のテキストファイル | — |
| C. YAML/JSON 設定 | 構造化設定ファイル | 外部パーサー依存、macOS Bash 3.2 との相性、要件外 |

### 引数なし `list` の対象

| 案 | 概要 | 不採用理由 |
|---|---|---|
| A. 引き続き `SUPPORTED_CLIS` 全件 | 全対応 CLI を一覧 | `install`/`doctor` と対象がずれる |
| B. `targets.txt` と揃える（採用） | install/list/doctor のデフォルト対象を統一 | — |

### コメントアウトした CLI の扱い

| 案 | 概要 | 不採用理由 |
|---|---|---|
| A. targets から外したら自動削除 | Terraform の destroy 的な振る舞い | 既存の正常な CLI やユーザー設定を破るリスク |
| B. 対象外にするだけ（採用） | install/list/doctor の対象から外すのみ | — |

### AI エージェントのインストール基盤

| 案 | 概要 | 不採用理由 |
|---|---|---|
| A. AI 専用レイヤを新設 | 別 manifest、別 install コマンド | 既存の provider 分離方針と重複 |
| B. 既存 provider に統合（採用） | `release-binary` / `official-installer` / `brew` | — |
| C. 全件 npm global | 統一しやすい | 公式配布が npm でない CLI が多い、system npm を上書きするリスク |

### カテゴリオプション（`--ai`, `--cloud`）

| 案 | 概要 | 不採用理由 |
|---|---|---|
| A. カテゴリフラグを追加 | `install --ai` など | targets.txt で十分、CLI 表面を複雑化 |
| B. 実装しない（採用） | targets.txt と明示引数のみ | — |

## 採用した仕様

### 3 層の役割分担

```text
targets.txt   = 利用者がインストール・更新したい CLI
SUPPORTED_CLIS = cli-toolbox が対応している全 CLI
manifest.tsv  = cli-toolbox が実際に導入した CLI の内部記録
```

`manifest.tsv` は廃止せず、所有権判定・provider 記録・安全な更新/削除に引き続き使用する。`targets.txt` から manifest は再生成しない。

### targets.txt

- リポジトリルートに配置（`CLI_TOOLBOX_TARGETS` でパス上書き可）
- 1 行 1 CLI、空行・行頭 `#` を無視、行末 `# コメント` を除去
- 重複は 1 件として扱う
- 未知の CLI 名はエラー（黙って無視しない）
- ファイル不存在または有効行ゼロは明確なエラー
- シェルのみでパース（`lib/targets.sh`）

### コマンド仕様

| コマンド | 引数なし | 引数あり |
|---|---|---|
| `install` | `targets.txt` の CLI を収束 | 指定 CLI のみ |
| `list` | `targets.txt` の CLI を表示 | 指定 CLI のみ |
| `doctor` | `targets.txt` の CLI を診断 | （引数なしのみ） |
| `delete` | エラー（常に明示指定必須） | cli-toolbox 管理分のみ削除 |

`targets.txt` からコメントアウトした CLI は自動削除しない。

### AI エージェント CLI

`targets.txt` および `SUPPORTED_CLIS` に追加:

```text
opencode
agent       # Cursor Agent CLI
codebuddy
claude
codex
agy
```

| CLI | provider | 備考 |
|---|---|---|
| `opencode` | release-binary / brew | GitHub release |
| `agent` | official-installer | Cursor Agent CLI、表示名 `agent (Cursor Agent CLI)` |
| `codebuddy` | brew / official-installer | Homebrew tap 優先 |
| `claude` | official-installer | `stable` チャネル |
| `codex` | official-installer | `CLI_TOOLBOX_HOME/bin` へ配置 |
| `agy` | official-installer | `--dir` で配置先指定 |

認証・ログイン・API キー設定は行わない。

## 判断理由

1. **targets.txt**: 利用者が fork やローカル編集で「何を収束させるか」をコード変更なしに制御できる。optional CLI（`glow`, `rg` など）は supported のまま残し、必要時だけ `install <name>` で足せる。
2. **list/doctor の対象統一**: 引数なしの 3 コマンドが同じ集合を見ることで、利用者の mental model を単純に保つ。
3. **コメントアウト ≠ 削除**: cli-toolbox の不変条件「管理外・既存の正常な CLI を削除しない」に合致。targets は「望む状態」の宣言であり、破壊的操作は `delete` に限定する。
4. **既存 provider への統合**: `install`/`delete`/`list`/`manifest` の枠組みを再利用し、AI 専用経路を増やさない。各 CLI の公式配布方式（installer / release / brew）に合わせて provider を選ぶ。
5. **カテゴリオプション不実装**: `targets.txt` のコメントセクション（`# AI agents`）で十分。CLI フラグを増やすメリットが小さい。

## 維持する安全原則

変更後も AGENTS.md の不変条件を維持する。

- `install` は冪等、同バージョン再実行は `unchanged`
- 更新失敗時は既存の正常な CLI を保持
- cli-toolbox 管理外・system / Homebrew / 既存 npm global を勝手に更新・削除しない
- 認証情報・設定・credential cache・shell 設定を変更しない
- `curl | bash` は使わず、ダウンロードと実行を分離
- 公式配布元のみ、checksum がある場合は検証（可能な範囲）
- `STATUS=managed` は manifest 記録がある場合のみ
- manifest と実体の両方から管理と確認できた成果物だけ削除

## 実装結果

### 主な変更

| ファイル | 内容 |
|---|---|
| `targets.txt` | デフォルト導入対象（cloud/ops + AI agents） |
| `lib/targets.sh` | パース、`load_targets`、`resolve_command_clis` |
| `lib/providers.sh` | `STANDARD_SET` 削除、AI CLI metadata |
| `lib/installers.sh` | AI CLI install/delete |
| `lib/common.sh` | version parser 追加 |
| `lib/packages.sh` | `codebuddy` brew tap |
| `cli-toolbox.sh` | targets 基準の install/list/doctor |
| `tests/test.sh` | 88 件のオフラインテスト（targets / AI / 非自動削除 等） |
| `README.md`, `docs/architecture.md`, `docs/adding-cli.md` | 利用者・実装者向けドキュメント更新 |

### テスト

```bash
shellcheck cli-toolbox.sh lib/*.sh tests/*.sh
bash tests/test.sh
# 88 passed, 0 failed
```

確認した主要挙動:

- 空行・コメント・行末コメント・重複除去
- 未知 CLI 名のエラー
- 引数なし `install` が `targets.txt` を使用
- 引数あり `install` が指定 CLI のみ使用
- targets 外化による自動削除なし
- manifest 管理物の明示 `delete`
- `agent (Cursor Agent CLI)` 表示
- 更新失敗時の既存バイナリ保持

## 今後の課題

1. **checksum 検証の強化**
   - `agent` / `opencode`: 公式 installer / release に install 時 checksum がない（警告のみ）
   - `claude` / `codex` / `agy`: 上流 installer 内検証に依存。cli-toolbox 側での独立検証は未実装

2. **配置先のばらつき**
   - `agent` / `claude` は `~/.local/bin` 配置になりうる（`tccli` と同様）。PATH 前提の利用者向け説明を継続する

3. **codebuddy のフォールバック**
   - Homebrew 非導入環境では公式 native installer（beta 系）に依存。stable な非 brew 経路（npm 等）の要否を再評価

4. **`list` の LATEST 取得**
   - 一部 AI CLI は manifest API 失敗時に `unknown` になる。取得経路の安定化または offline 時の表示改善

5. **実機での各 AI CLI install 検証**
   - オフラインテストは mock installer 中心。Linux/macOS × amd64/arm64 での実インストール確認が残る
