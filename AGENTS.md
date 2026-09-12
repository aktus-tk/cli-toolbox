# AGENTS.md

## Scope

このリポジトリは、複数のCLIをLinux/macOSのユーザー環境へ冪等に導入・更新するためのbootstrapperです。

CLI本体の機能、クラウド認証、運用wrapperは実装しません。

## Core invariants

変更時は、以下を必ず維持してください。

1. `install`は冪等である
2. 同じバージョンの再実行は`unchanged`になる
3. 更新失敗時は既存の正常なCLIを維持する
4. cli-toolbox管理外のCLIを削除・上書きしない
5. 認証情報・設定・credential cacheを変更しない
6. shell設定ファイルを自動変更しない
7. `curl | bash`を使用しない
8. 公式配布元だけを使用する
9. 公式checksumがある場合は必ず検証する
10. archive展開前にパストラバーサルを検査する
11. Linux amd64/arm64とmacOS amd64/arm64を考慮する
12. macOS標準Bash 3.2とBSD userlandで動作させる
13. stdoutは機械処理可能な出力、警告・エラーはstderrへ出す
14. バージョン取得失敗だけで既存CLIを破壊しない

## Provider policy

CLIとインストール方式を分離してください。

利用可能なprovider：

- `apt`
- `brew`
- `brew-cask`
- `uv-tool`
- `official-installer`
- `official-archive`
- `release-binary`
- `system-package`
- `unknown`

providerはOSごとに解決します。APTやHomebrewを全OS共通として扱わないでください。

Python製CLIは原則として`uv tool`で隔離します。ただし、公式のstandalone配布物が適切な場合はそちらを優先できます。

## Managed ownership

`STATUS=managed`は、manifestにcli-toolboxが導入した記録がある場合だけ使用してください。

実行ファイルが`~/.cli-toolbox`内にあるという理由だけで、所有権を推測しないでください。

削除できるのは、manifestと実体の両方からcli-toolbox管理と確認できた成果物だけです。

特に以下を守ってください。

- 既存のAPT/Homebrew packageを自動削除しない
- cli-toolbox導入前から存在する`uv tool`を削除しない
- `/usr/bin`、`/usr/local/bin`、`/opt/homebrew`を直接削除しない
- `$HOME`や広いディレクトリを再帰削除しない
- 削除対象パスを明示的に検証する

## CLIの追加・削除

CLIを追加・削除するときは、`docs/adding-cli.md`のチェックリストをすべて確認してください。一部だけ変更した状態で完了としないでください。

## Verification

変更後は必ず実行してください。

```bash
shellcheck cli-toolbox.sh lib/*.sh tests/*.sh
bash tests/test.sh
```
