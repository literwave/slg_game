#!/bin/sh

# 热更 lua 文件 / 重载配置表
#   sh shell/hot_update.sh                         # 热更上次成功之后改过的 lua
#   sh shell/hot_update.sh logic/service/agent/module/hero/mgr.lua [更多文件...]
#   sh shell/hot_update.sh -c                      # 只重载配置表
#   sh shell/hot_update.sh -c logic/define/const.lua
# 不带文件时，用 log/hot_update.stamp 记录的上次成功时间做对比；还没有记录就用服务器进程启动时间。
# 配置表（game_common/server/res、res/innerCity.lua）有更新时会自动带上重载。
# 路径相对项目根目录。改 orm/schema/*.td 或协议需要重启

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONFIG_FILE="$PROJECT_ROOT/config/main_node"
STAMP_FILE="$PROJECT_ROOT/log/hot_update.stamp"

# 配置文件可能是 CRLF，先去掉 \r；值取到空白/引号为止，忽略行尾注释
read_cfg() {
	tr -d '\r' < "$CONFIG_FILE" | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"[:space:]]*\).*/\1/p" | head -n 1
}

HTTP_PORT=$(read_cfg http_port)
HTTP_PORT=${HTTP_PORT:-33023}

CONFIG=0
if [ "$1" = "-c" ]; then
	CONFIG=1
	shift
fi

# 对比时间：上次热更成功的时刻；第一次用正在跑的 skynet 启动时间
baseline() {
	if [ -f "$STAMP_FILE" ]; then
		base=$(tr -d '[:space:]' < "$STAMP_FILE")
		if echo "$base" | grep -q '^[0-9][0-9]*$'; then
			echo "$base"
			return
		fi
	fi
	pid=$(pgrep -f "skynet ../config/main_node" | head -n 1)
	if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
		stat -c %Y "/proc/$pid"
	fi
}

save_stamp() {
	mkdir -p "$PROJECT_ROOT/log"
	echo "$1" > "$STAMP_FILE"
}

AUTO=0
if [ $# -eq 0 ] && [ "$CONFIG" = "0" ]; then
	AUTO=1
fi

SCAN_AT=$(date +%s)
FILES=""
if [ "$AUTO" = "1" ]; then
	BASE=$(baseline)
	if [ -z "$BASE" ]; then
		echo "错误: 没有热更记录，也找不到正在运行的服务器，无法按修改时间对比" >&2
		exit 1
	fi
	cd "$PROJECT_ROOT" || exit 1
	CHANGED=$(find logic common orm start_up -type f -name '*.lua' -newermt "@$BASE" -printf '%p\n' | sort)
	CONFIG_CHANGED=$(find game_common/server/res -type f -name '*.lua' -newermt "@$BASE" -printf '%p\n' | sort)
	if [ -f res/innerCity.lua ] && [ "$(stat -c %Y res/innerCity.lua)" -gt "$BASE" ]; then
		CONFIG_CHANGED="${CONFIG_CHANGED:+$CONFIG_CHANGED
}res/innerCity.lua"
	fi
	if [ -n "$CONFIG_CHANGED" ]; then
		CONFIG=1
	fi
	if [ -z "$CHANGED" ] && [ "$CONFIG" = "0" ]; then
		echo "没有晚于 $(date -d "@$BASE" '+%F %T') 的 lua 或配置修改"
		save_stamp "$SCAN_AT"
		exit 0
	fi
	echo "对比 $(date -d "@$BASE" '+%F %T') 之后的修改"
	if [ -n "$CHANGED" ]; then
		OLDIFS=$IFS
		IFS='
'
		for f in $CHANGED; do
			echo "  $f"
			FILES="${FILES:+$FILES,}$f"
		done
		IFS=$OLDIFS
	fi
	if [ -n "$CONFIG_CHANGED" ]; then
		echo "配置表有修改，一并重载"
		OLDIFS=$IFS
		IFS='
'
		for f in $CONFIG_CHANGED; do
			echo "  $f"
		done
		IFS=$OLDIFS
	fi
else
	for f in "$@"; do
		f=${f#../}
		f=${f#./}
		if [ ! -f "$PROJECT_ROOT/$f" ]; then
			echo "错误: 找不到文件 $f（路径相对项目根目录）" >&2
			exit 1
		fi
		FILES="${FILES:+$FILES,}$f"
	done
fi

OUT=$(curl -sS --max-time 60 -w "\n%{http_code}" "http://127.0.0.1:$HTTP_PORT/?method_tag=2&config=$CONFIG&files=$FILES" 2>&1)
CURL_RET=$?
HTTP_CODE=$(echo "$OUT" | tail -n 1)
RESULT=$(echo "$OUT" | sed '$d')
if [ "$CURL_RET" -ne 0 ]; then
	echo "错误: 请求 127.0.0.1:$HTTP_PORT 失败 (curl=$CURL_RET)：$RESULT" >&2
	echo "检查服务器是否在跑、http_port 是否一致" >&2
	exit 1
fi
echo "$RESULT"
if [ "$HTTP_CODE" = "200" ] && [ "$(echo "$RESULT" | head -n 1)" = "ok" ]; then
	if [ "$AUTO" = "1" ]; then
		save_stamp "$SCAN_AT"
	fi
	exit 0
fi
exit 1
