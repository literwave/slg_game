#!/bin/sh

# 连接 skynet debug console。端口读 config/main_node 的 console_port
#   sh shell/console.sh

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG_FILE="$SCRIPT_DIR/../config/main_node"

read_cfg() {
	tr -d '\r' < "$CONFIG_FILE" | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"[:space:]]*\).*/\1/p" | head -n 1
}

PORT=$(read_cfg console_port)
PORT=${PORT:-8000}

if ! command -v telnet >/dev/null 2>&1; then
	echo "错误: 没有 telnet，无法连接 127.0.0.1:$PORT" >&2
	exit 1
fi

exec telnet 127.0.0.1 "$PORT"
