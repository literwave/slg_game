#!/bin/sh
# 使用 config/main_node 中的连接参数，只读配置；测试数据在独立临时库，结束时删除该测试库。
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RESULT=$(mktemp)
trap 'rm -f "$RESULT"' EXIT
cd "$ROOT/skynet"
timeout 45 ./skynet ../config/persistence_test_node >"$RESULT" 2>&1 || {
	cat "$RESULT"
	exit 1
}
cat "$RESULT"
grep -q '^PERSISTENCE_INTEGRATION_PASS$' "$RESULT"
