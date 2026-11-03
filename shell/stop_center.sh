#!/bin/sh

# 中心节点安全关服：经 mcs 按顺序关服务

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG_FILE="$SCRIPT_DIR/../config/center_node"
WAIT_SEC=${WAIT_SEC:-60}

read_cfg() {
	tr -d '\r' < "$CONFIG_FILE" | sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"[:space:]]*\).*/\1/p" | head -n 1
}

HTTP_PORT=$(read_cfg http_port)
HTTP_PORT=${HTTP_PORT:-33024}

PID_LIST=$(pgrep -f "skynet ../config/center_node")
if [ -z "$PID_LIST" ]; then
	echo "中心节点没在运行"
	exit 0
fi
if [ "$(echo "$PID_LIST" | wc -l)" -gt 1 ]; then
	echo "错误: 有多个中心节点进程在跑: $(echo $PID_LIST)" >&2
	exit 1
fi
PID=$PID_LIST

echo "正在关闭中心节点 (pid=$PID, http_port=$HTTP_PORT)..."
OUT=$(curl -sS --max-time 120 -w "\n%{http_code}" "http://127.0.0.1:$HTTP_PORT/?method_tag=1" 2>&1)
CURL_RET=$?
HTTP_CODE=$(echo "$OUT" | tail -n 1)
RESULT=$(echo "$OUT" | sed '$d')
if [ "$CURL_RET" -ne 0 ]; then
	echo "错误: 请求 127.0.0.1:$HTTP_PORT 失败 (curl=$CURL_RET)：$RESULT" >&2
	exit 1
fi
echo "mcs: $RESULT"
case "$HTTP_CODE:$RESULT" in
	200:stopped*) ;;
	*)
		echo "错误: 关服没有执行 (http=$HTTP_CODE)，进程仍在运行" >&2
		exit 1
		;;
esac

i=0
while kill -0 "$PID" 2>/dev/null; do
	if [ "$i" -ge "$WAIT_SEC" ]; then
		echo "错误: ${WAIT_SEC} 秒后进程仍在，请看日志确认是否卡在某个服务" >&2
		exit 1
	fi
	sleep 1
	i=$((i + 1))
done
echo "中心节点已关服"
