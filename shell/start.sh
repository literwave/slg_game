#!/bin/sh

# Skynet 游戏服务器启动脚本
#   sh shell/start.sh      后台运行，日志写 log/skynet.log，随后 tail -f。Ctrl+C 只停看日志
#   sh shell/start.sh -f   前台运行（调试用，ctrl+c 直接杀进程，未落盘数据会丢）
# 关服用 sh shell/stop.sh

FOREGROUND=0
if [ "$1" = "-f" ]; then
	FOREGROUND=1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

cd "$PROJECT_ROOT" || {
	echo "错误: 无法切换到项目根目录 $PROJECT_ROOT" >&2
	exit 1
}

# 定义路径
SKYNET_DIR="$PROJECT_ROOT/skynet"
SKYNET_BIN="$SKYNET_DIR/skynet"
CONFIG_FILE="../config/main_node"

# 检查 skynet 目录与可执行文件
if [ ! -d "$SKYNET_DIR" ]; then
    echo "错误: 找不到 skynet 目录: $SKYNET_DIR" >&2
    exit 1
fi

if [ ! -f "$SKYNET_BIN" ]; then
    echo "错误: 找不到 skynet 可执行文件: $SKYNET_BIN" >&2
    exit 1
fi

# 检查 skynet 是否有执行权限
if [ ! -x "$SKYNET_BIN" ]; then
    echo "错误: skynet 文件没有执行权限: $SKYNET_BIN" >&2
    exit 1
fi

# 检查配置文件是否存在（相对 skynet 目录）
if [ ! -f "$SKYNET_DIR/$CONFIG_FILE" ]; then
    echo "错误: 找不到配置文件: $SKYNET_DIR/$CONFIG_FILE" >&2
    exit 1
fi

# 启动服务器（从 skynet 目录运行以匹配配置里的相对路径）
echo "正在启动 Skynet 服务器..."
echo "配置文件: $CONFIG_FILE"
echo "工作目录: $SKYNET_DIR"
echo "----------------------------------------"

OLD_PID=$(pgrep -f "skynet $CONFIG_FILE")
if [ -n "$OLD_PID" ]; then
	echo "错误: 服务器已在运行 (pid=$(echo $OLD_PID))，先 sh shell/stop.sh" >&2
	exit 1
fi

cd "$SKYNET_DIR" || {
    echo "错误: 无法切换到 Skynet 目录 $SKYNET_DIR" >&2
    exit 1
}

if [ "$FOREGROUND" = "1" ]; then
	exec "$SKYNET_BIN" "$CONFIG_FILE"
fi

LOG_DIR="$PROJECT_ROOT/log"
LOG_FILE="$LOG_DIR/skynet.log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
START_LINE=$(($(wc -l < "$LOG_FILE") + 1))
# 新开会话脱离当前终端，ctrl+c / 关终端的信号到不了 skynet
setsid nohup "$SKYNET_BIN" "$CONFIG_FILE" >> "$LOG_FILE" 2>&1 < /dev/null &
PID=$!
echo "后台启动 pid=$PID，Ctrl+C 只停止看日志。关服: sh shell/stop.sh"
exec tail -n +"$START_LINE" -f "$LOG_FILE"