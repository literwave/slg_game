#!/bin/sh

# 安全关服后重新启动。随后和 start.sh 一样 tail 当天的 common_debug 日志；-f 则前台运行

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

sh "$SCRIPT_DIR/stop.sh" || exit 1
exec sh "$SCRIPT_DIR/start.sh" "$@"
