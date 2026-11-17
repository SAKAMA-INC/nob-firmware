#!/usr/bin/env bash
# サブモジュールに当てるパッチを、まとめて当てる。
#
#   git submodule update --init --recursive
#   ./patches/apply.sh
#
# patches/<サブモジュールのパス>/*.patch を、そのサブモジュールの中で git apply する。
# 当て済みのパッチは飛ばすので、何度実行してもよい。
# サブモジュールを更新（git submodule update）すると変更は消えるので、そのたびに実行する。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

status=0
while IFS= read -r -d '' patch; do
  rel="${patch#patches/}"
  dir="$(dirname "${rel}")"
  abs_patch="$root/$patch"
  if [ ! -d "$dir" ]; then
    echo "NG   ${rel}: ${dir} がありません。先に git submodule update --init --recursive を実行してください" >&2
    status=1
    continue
  fi
  if git -C "$dir" apply --check -R "$abs_patch" >/dev/null 2>&1; then
    echo "skip ${rel}（当て済み）"
  elif git -C "$dir" apply --check "$abs_patch" >/dev/null 2>&1; then
    git -C "$dir" apply "$abs_patch"
    echo "ok   ${rel}"
  else
    echo "NG   ${rel}: 当てられません。サブモジュールの版が変わっていないか確認してください" >&2
    status=1
  fi
done < <(find patches -name '*.patch' -print0 | sort -z)

exit "$status"
