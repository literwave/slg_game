# Game Demo Framework

基于 [Skynet](https://github.com/cloudwu/skynet) 的 Lua SLG 服务端，单进程里可以跑登录、网关、玩家逻辑和 Mongo 存盘，并带关服、热更、日志、单元测试和压测。

用来在上面做中小型 SLG 玩法。本机 1000 人同时在线、大约 5100 req/s 读请求时没有压力，p99 约 4ms（见 [PERFORMANCE_ANALYSIS.md](PERFORMANCE_ANALYSIS.md)）。1000 人以上还没测。多服拆分、运行时监控，以及建造队列、邮件、聊天这几块协议还没做完，见 [已知限制](#已知限制)。

配套客户端：[slg_game_client](https://github.com/literwave/slg_game_client)（Cocos Creator 3.8.8 制作的小型 SLG，登录服 `33021`、网关 `33022`）。

安装和进程怎么拆，看 [安装步骤](#安装步骤) 与 [架构总览](#架构总览)。

---

## 目录

- [特性](#特性)
- [技术栈](#技术栈)
- [架构总览](#架构总览)
- [玩家登录过程](#玩家登录过程)
- [仓库结构](#仓库结构)
- [环境要求](#环境要求)
- [Windows：用 WSL2](#windows用-wsl2)
- [安装步骤](#安装步骤)
- [配置说明](#配置说明)
- [数据与 ORM](#数据与-orm)
- [开发指南](#开发指南)
- [脚本一览](#脚本一览)
- [文档索引](#文档索引)
- [已知限制](#已知限制)
- [License](#license)

---

## 特性

| 能力 | 说明 |
|------|------|
| Actor 服务拆分 | 登录 / 网关 / Agent / 全局业务 / DB 职责清晰 |
| WebSocket 网关 | 二进制帧 + protobuf，适合实时客户端 |
| 玩家级串行队列 | 同 `userId` 串行、跨玩家并行，降低竞态 |
| Agent 池 | 玩家按 `userId` 固定落到同一个 agent，重连不会同时进两个 |
| 网关多 worker | `gated` 只负责接入，连接轮流交给 `gate_cnt` 个 worker 并行读写 |
| 安全关服 | `shell/stop.sh` 按依赖顺序下线并落盘，进程再退出 |
| 热更 | `shell/hot_update.sh` 先整体编译，有一个文件编译失败就整批不生效 |
| 日志 | 按级别分文件；钻石、资源、道具、英雄的变动另写流水 |
| MongoDB 持久化 | 统一走 `.mongodb`；业务侧 schema 驱动存盘 |
| 配置热加载入口 | `load_xls` + 导表产物 |
| 测试 | `shell/test.sh` 做语法和单元测试；`shell/bench.sh` 压登录和读请求；CI 覆盖起服、压测、顶号、关服 |

---

## 技术栈

- **运行时**：Skynet v1.6.0（Lua 5.4.5，`skynet/` 为 submodule）
- **传输**：WebSocket
- **协议**：Protobuf（`game_common/pb`、`game_common/proto`，协议号在 `game_common/server/net_pb.lua`）
- **存储**：MongoDB 3.6 及以上（驱动为 OP_MSG）、Redis（登录 token 等）
- **数据模型**：ORM（`lualib/orm` + `orm/schema/*.td`）
- **大地图寻路**：JPS（`vendor/slg-navigation` submodule）
- **视野**：AOI（[`cloudwu/aoi`](https://github.com/cloudwu/aoi)，`vendor/aoi` submodule）。`require "aoi"`，半径在上游写死为 10

---

## 架构总览

### 服务拓扑

入口：`start_up/main_start.lua`

```text
                    +-----------+
                    |  Client   |
                    +-----+-----+
                          |
            WebSocket     |     WebSocket
         (login_port)     |    (gate_port)
                          v
                    +-----------+         +------------+
                    |  logind   | ------> |   Redis    |  (token)
                    +-----+-----+         +------------+
                          | 签发 token + gate 地址
                          v
                    +-----------+
                    |   gated   |  只监听、接入，连接轮流分发
                    +-----+-----+
                          |
              +-----------+-----------+
              v           v           v
          +---------+ +---------+ +---------+
          | worker  | | worker  | |   ...   |  读写 / 登录校验 / 转发
          +----+----+ +----+----+ +----+----+
               |           |
               +-----+-----+
                     | 按 userId 取模，固定落到同一个
         +-----------+-----------+
         v           v           v
     +-------+   +-------+   +-------+
     | agent |   | agent |   |  ...  |  玩家业务
     +---+---+   +---+---+   +---+---+
         |           |
         +-----+-----+
               v
            +---------------+     +------------+
            | main_mongodb  | --> |  MongoDB   |
            |   (.mongodb)  |     +------------+
            +---------------+

  旁路服务: gameserver / game_sid / mail / world / mcs(HTTP) / gamelog / load_xls
```

### 并发约定

- **gated**：只 `listen` / `accept`，连接轮流交给 `gate_cnt` 个 `gate_worker`
- **gate_worker**：各自独立做 WebSocket 读写、token 校验和转发，连接压力摊到多个服务上
- **agent**：玩家按 `userId % agent 数` 固定分配；每个 `userId` 一个 `queue()`，同玩家串行、异玩家并行。同一玩家再登录会踢掉旧连接，旧连接迟到的断线不会把新会话登出
- 断线由持有该连接的 worker 通知 agent 的 `disconnect`

---

## 玩家登录过程

以本机默认配置为例：登录 `33021`，网关 `33022`，`host_id` / `serverId` 为 `120`。玩家账号 `alice`、密码 `123`，PC 登录（`accountType = 1`）。

```text
Client          logind            Redis           gated         worker          agent         MongoDB
  |               |                 |               |              |               |              |
  |-- WS :33021 ->|                 |               |              |               |              |
  | c2s_user_login|                 |               |              |               |              |
  |               |-- 查/建账号 --->|               |              |               |              |
  |               |-- 写 token ---->|               |              |               |              |
  |<- s2c_user_login (gateAddr + token)，随后断开   |              |               |              |
  |               |                 |               |              |               |              |
  |-- WS :33022 ------------------------------->|              |               |              |
  |               |                 |               |-- 轮流分发 ->|               |              |
  | c2s_verify_login ----------------------------------------->|               |              |
  |               |                 |<-- 校验 token ------------|               |              |
  |               |                 |               |              |-- login ----->|              |
  |               |                 |               |              |               |-- 读档 ----->|
  |<- s2c_user_login_ok ---------------------------------------|               |              |
  |   之后业务包走 worker → agent                              |               |              |
```

1. **连登录服**  
   客户端 WebSocket 连 `logind:33021`，发 `Login.c2s_user_login`（账号、密码、`serverId`）。  
   Master 按轮询把连接交给某个 login slave。

2. **校验账号、签发 token**  
   `accountType = 1` 走 PC 登录。`ACCOUNT.sdkLoginOk` 用 Redis 查账号是否已有 `userId`：没有则向 `.game_sid` 要新 ID 并写回 Redis。  
   按 `serverId` 从已注册的 gate 里挑一个，生成 token（约 300 秒过期），Redis 记下 `{userId, passwd, serverId, account}`。

3. **回 gate 地址后断开**  
   回 `Login.s2c_user_login`（`gateAddr`、`token`、`userId`），然后关掉这条登录连接。登录服不持游戏长连接。

4. **连网关并验 token**  
   客户端用 `gateAddr` 连 `gated:33022`。`.gated` 接受连接后轮流交给某个 `gate_worker`，整条连接之后的读写都在这个 worker 里。  
   客户端发 `Login.c2s_verify_login`（`token`、`userId`、`passwd`），worker 从 Redis 取出 token 记录，对不上就关掉连接。

5. **进 agent**  
   worker 按 `userId % agent 数` 选出 agent（同一个玩家每次都是同一个），`skynet.call(agent, "lua", "login", ...)`。  
   agent 向 Mongo 读档：没有存档则建新玩家，否则加载玩家对象；挂心跳，并通知 `.gameserver`、`.mail`。  
   **此时还不进 world**，进大世界时再通知 `.world`。  
   这个玩家如果已经在线，agent 先踢掉旧连接再登录，两个连接不会同时生效。

6. **登录完成，之后走业务**  
   worker 记下 `fd → agent`，回 `Login.s2c_user_login_ok`。  
   之后这条连接上的包由 worker 转给该 agent；存档走 `agent → .mongodb`。断线时 worker 调 agent 的 `disconnect`。

---

## 仓库结构

```text
slg_game/
├── README.md                 # 本文件
├── start_up/                 # Skynet 启动脚本
│   └── main_start.lua
├── config/                   # 节点配置
│   ├── main_node             # 120 服
│   ├── clustername.lua       # Skynet cluster 节点地址
│   ├── test_node             # 测试节点
│   └── bench_node            # 压测机器人节点
├── shell/                    # 启停 / 编译 / 测试 / 压测 / 清库脚本
├── logic/
│   ├── service/              # Skynet 服务实现
│   │   ├── logind/           # 登录
│   │   ├── gated/            # 网关入口：监听、接入、关服
│   │   ├── gate_worker/      # 网关 worker：连接读写、登录校验、转发
│   │   ├── agent/            # 玩家逻辑（模块在 module/ 下）
│   │   ├── gameserver/       # 全局协调
│   │   ├── main_mongodb/     # Mongo 访问（注册 .mongodb）
│   │   ├── game_sid/         # 玩家 ID
│   │   ├── mail/ world/ mcs/ ...
│   ├── define/               # 常量与表数据访问
│   └── base/                 # OOP / 工具基础库
├── common/                   # preload、Import、通用工具
├── orm/
│   ├── init.lua              # 游戏侧 ORM 入口（加载 .td）
│   └── schema/               # 持久化 schema（user.td / hero.td）
├── lualib/                   # 游戏侧 Lua 库（非 Skynet 官方）
│   ├── orm/                  # create / dump / typedef
│   ├── protobuf.lua
│   ├── aoi.lua               # AOI 的 Lua 入口
│   └── aoi_binding.c         # 编译成 skynet/luaclib/aoi/c.so
├── vendor/pbc/               # pbc 源码（protobuf C 实现）
├── vendor/slg-navigation/    # submodule：SLG JPS 寻路
├── vendor/aoi/               # submodule：cloudwu/aoi，视野
├── skynet/                   # submodule：cloudwu/skynet（当前 v1.6.0）
├── game_common/              # submodule：协议、pb、导表（literwave/game_common）
├── res/innerCity.lua         # 本服内城布局，不在 game_common 里
├── docs/                     # 专题设计文档
├── .github/workflows/ci.yml  # CI
└── test/                     # 联调脚本
    ├── unit/                 # 单元测试（shell/test.sh 调用）
    └── bench/                # 压测机器人（shell/bench.sh 调用）
```

---

## 环境要求

| 项目 | 建议 |
|------|------|
| OS | Linux / macOS。Windows 按 [Windows：用 WSL2](#windows用-wsl2) 装 **Ubuntu 22.04** |
| 编译器 | gcc、make、autoconf（Skynet 的 jemalloc 需要） |
| 依赖服务 | Redis；MongoDB **3.6 及以上**（本机无鉴权即可跑通默认配置） |
| Git | 能拉 GitHub SSH（`skynet` / `game_common` 子模块地址是 `git@github.com:...`） |
| 网络 | 120 服：`login 33021` / `gate 33022` / `http 33023` / console `8000` / cluster `2528` |

Ubuntu / Debian / WSL2 编译依赖：

```bash
sudo apt update
sudo apt install -y git build-essential autoconf
```

Windows 从这里开始：[Windows：用 WSL2](#windows用-wsl2)。发行版用 **Ubuntu 22.04**。装好后，下面的安装步骤都在这个 WSL 终端里执行。

---

## Windows：用 WSL2

服务端在 WSL2 的 **Ubuntu 22.04** 里编译和启动。Cocos 客户端可以继续留在 Windows。

### 1. 安装 Ubuntu 22.04

用管理员打开 PowerShell：

```powershell
wsl --install -d Ubuntu-22.04
```

发行版名字是 `Ubuntu-22.04`，不要装不带版本号的 `Ubuntu`（那是当前最新 LTS）。装完重启，按提示建 Linux 用户。确认版本和 WSL2：

```powershell
wsl -l -v
```

`NAME` 为 `Ubuntu-22.04`，`VERSION` 为 `2`。若版本是 `1`：

```powershell
wsl --set-version Ubuntu-22.04 2
```

进系统后可以核对：

```bash
lsb_release -rs    # 22.04
```

### 2. 打开 systemd

Redis、Mongo 的 `systemctl` 需要它。Ubuntu 22.04 的 WSL 镜像通常已经打开。在 WSL 里执行 `systemctl status`，若提示 systemd 未运行，把下面写进 `/etc/wsl.conf`：

```ini
[boot]
systemd=true
```

然后在 Windows PowerShell 里执行 `wsl --shutdown`，再重新打开 Ubuntu 22.04。

### 3. 仓库放在 Linux 磁盘

克隆到家目录，例如 `~/slg_game`。不要放在 `/mnt/c` 或 `/mnt/d`。Windows 盘在 WSL 里是网络文件系统，Skynet 编译会很慢，权限和文件监视也容易出问题。

Cursor 用 **WSL** 窗口打开这个目录，不要用 Windows 路径打开同一份代码。

### 4. SSH 配在 WSL 里

子模块地址是 `git@github.com:...`。密钥要在 Ubuntu 22.04 里生成并加到 GitHub，Windows 里的 key 不会自动带进来：

```bash
ssh-keygen -t ed25519 -C "your-email"
cat ~/.ssh/id_ed25519.pub
ssh -T git@github.com
```

### 5. Windows 客户端怎么连

`config/main_node` 监听 `0.0.0.0`。Windows 11 会把 WSL 端口转到本机，客户端填：

- 登录 `ws://127.0.0.1:33021`
- 网关 `ws://127.0.0.1:33022`

连不上时，在 WSL 里看地址：

```bash
hostname -I
```

客户端改用这个 IP。防火墙放行 `33021`、`33022`。

接下来按 [安装步骤](#安装步骤) 在同一个 Ubuntu 22.04 终端里装 Redis、Mongo、编译并启动。

---

## 安装步骤

Skynet 来自 [cloudwu/skynet](https://github.com/cloudwu/skynet)，当前钉在 **v1.6.0**（Lua 5.4.5）。协议和导表来自 [game_common](https://github.com/literwave/game_common)，应对齐 **master**。工作区只检出 `pb/`、`proto/`、`server/`（`net_pb.lua` 和 `server/res`）。上游 README、客户端 JSON、`tsv/`、导表工具不会检出。

### 1. 安装 Redis

```bash
sudo apt install -y redis-server
sudo systemctl enable --now redis-server
```

默认配置 `redis_password` 为空，本机 Redis **不要**设 `requirepass`。确认：

```bash
redis-cli ping    # 应返回 PONG
```

### 2. 安装 MongoDB

默认配置 `mongodb_user` / `mongodb_password` 为空，本机 Mongo **不要开鉴权**，监听 `127.0.0.1:27017`。

Skynet v1.6.0 的 Mongo 驱动使用 OP_MSG，find、update、insert 都走它。MongoDB 从 **3.6** 起支持这套协议，**5.1** 起只接受它。本仓库可连 **3.6 及以上**，包括 6、7、8。

安装后确认：

```bash
ss -ltnp | grep 27017
# 或
mongosh --eval 'db.runCommand({ ping: 1 })'
```

`shell/start_db.sh` 里的路径是 `/usr/local/mongodb`、`/usr/local/redis` 模板。用系统包安装时不必跑这个脚本，用 `systemctl` 即可。

### 3. 克隆仓库与子模块

本机需已配置 [GitHub SSH key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh)。

```bash
git clone --recurse-submodules git@github.com:literwave/slg_game.git
cd slg_game
```

若已经克隆但 `skynet/`、`game_common/` 是空的：

```bash
git submodule update --init --recursive
```

`game_common` 拉下来后只保留协议和导表。Git 不允许在 `.gitmodules` 里写自动执行的命令，所以这一步要在本机跑：

```bash
git -C game_common sparse-checkout init
git -C game_common sparse-checkout set '/pb/' '/pb/**' '/proto/' '/proto/**' '/server/' '/server/**'
```

这样工作区里不会有上游 README、`client/`、`tsv/`、`ptotools/`、`vis_conf/`。

要对齐 **master** 上的协议和导表，路径必须写上 `game_common`：

```bash
git submodule update --init --remote game_common
```

不要运行不带路径的 `git submodule update --remote`。它会更新每一个子模块。`skynet` 在 `.gitmodules` 里没有 `branch`，Git 会跟远程默认分支，也就是上游 master，从而离开钉住的 **v1.6.0**。`skynet` 只随父仓库记录的提交走：`git submodule update skynet`。

确认：

```bash
ls skynet/Makefile game_common/server/res/Item.lua game_common/pb/common.pb game_common/server/net_pb.lua vendor/slg-navigation/Makefile vendor/aoi/aoi.h
```

### 4. 编译 Skynet、protobuf、寻路与 AOI

编译产物（`skynet/skynet`、`skynet/luaclib/*.so`）已 gitignore，克隆后必须本地编一次：

```bash
make
# 或
sh shell/build.sh
```

macOS 会走 `make macosx`。成功后应存在：

- `skynet/skynet`
- `skynet/luaclib/protobuf.so`
- `skynet/luaclib/navigation/c.so`
- `skynet/luaclib/aoi/c.so`

`make` 提示 `Nothing to be done` 且上述文件都在，就是已经编过了。

### 5. 核对配置

打开 [`config/main_node`](config/main_node)，本机默认即可：

| 项 | 默认 |
|----|------|
| `login_port` / `gate_port` / `http_port` | `33021` / `33022` / `33023` |
| `mongodb_host` / `mongodb_port` | `127.0.0.1` / `27017` |
| `mongodb_user` / `mongodb_password` | 空 |
| `redis_host` / `redis_port` / `redis_password` | `127.0.0.1` / `6379` / 空 |
| `protocol` | `ws` |

改端口或远程 DB 时改这一份即可。

### 6. 启动

```bash
sh shell/start.sh
```

后台运行，输出追加到 `log/skynet.log`。脚本每秒询问服务状态，所有服务拉起后打印「启动完成」，关终端不影响服务器。

```bash
tail -f log/skynet.log    # 看日志，ctrl+c 只停 tail
sh shell/start.sh -f      # 前台运行，调试用
```

`-f` 模式下 `Ctrl+C` 会直接杀掉进程，还没落盘的数据会丢，正常停服用：

```bash
sh shell/stop.sh
```

它按顺序停登录、踢下线、各服务落盘、关数据库，确认进程退出后才返回。

Debug console（telnet）：

```bash
telnet 127.0.0.1 8000
```

### 7.（可选）测试节点

```bash
sh shell/runtest.sh
```

### 8. 测试与压测

不用起服的检查（lua 语法、shell 语法、单元测试），编译过就能跑：

```bash
sh shell/test.sh
```

压测：对已经在运行的服务器起一批机器人，走完整登录，然后循环发系统开放、基础信息、部队、英雄请求，并保持心跳。结束打印每个协议的延迟分位数，失败比例超过上限时退出码为 1。

```bash
sh shell/bench.sh                          # 默认 100 人、30 秒
sh shell/bench.sh -u 1000 -d 60 -r 10 -i 200
sh shell/bench.sh --relogin                # 顶号检查
```

机器人账号是 `bench_<序号>`，会在当前配置的库里建号；重复跑同样的参数复用同一批号。不要对正式数据的服跑。

### 9. CI

`.github/workflows/ci.yml` 在 push / PR 时跑两个任务：

- 编译后执行 `shell/test.sh`
- 用 Mongo、Redis 容器起服，`bench.sh` 200 人压测（要求零失败、p99 不超过 200ms），`--relogin` 顶号检查，最后 `stop.sh` 关服。失败时上传 `log/`

---

## 配置说明

主配置文件：`config/main_node`（相对 `skynet/` 目录加载）。

| 配置项 | 含义 |
|--------|------|
| `host_id` | 本服 ID |
| `nodename` / `cluster` | 节点前缀，启动时拼上 `host_id`；以及 `config/clustername.lua` 路径 |
| `gate_port` / `login_port` / `http_port` | 网关 / 登录 / HTTP 运维端口 |
| `gate_cnt` | 网关 worker 数，同一端口，连接轮流分给各 worker |
| `agent_init_cnt` | agent 数，玩家按 `userId % agent_init_cnt` 固定分配。改这个数要重启，运行中不能改 |
| `logpath` / `log_level` | 日志目录；`debug` / `info` / `warn` / `error`，低于该级别不写 |
| `mongodb_*` | Mongo 连接 |
| `redis_*` | Redis 连接 |
| `rootdir` / `workdir` | 工程与 logic 相对路径 |

测试配置见 `config/test_node`。

### 共享配置与协议

客户端和服务端必须使用同一个 `game_common` 提交。需要更新到上游 `master` 时，先确认子模块没有未提交修改，再执行：

```bash
git -C game_common fetch origin master
git -C game_common checkout --detach origin/master
git -C game_common submodule update --init --recursive
bash shell/test.sh
```

随后提交父仓库的子模块引用；其他环境用 `git submodule update --init --recursive` 还原该版本。这个命令本身不会追踪最新 `master`。

枚举从 `game_common/server/enum` 加载，数据表从 `server/Res` 加载。排行榜数量读取 `Rank.RankMax`，资源地首次占领奖励读取 `ResLandFirst`，同一玩家的同类型、同等级只领取一次。石料使用道具 4、令牌使用道具 100；新角色直接按 `Global.Id=1` 发放初始道具。本版本按清档后的新数据结构运行，不迁移旧资源余额。

本次还接入了其他玩家公开资料、可见行军路径查询，以及势力、击杀、城建、同盟四类排行榜。更新协议或 `orm/schema/*.td` 后需要正常关服、重新起服，不能只热更业务 Lua；上线前应备份数据并同时更新客户端配置。

### Cluster

`config/clustername.lua` 里每个服一行，键是 `nodename` 拼上 `host_id`。当前只有 120 服：`nodename` 是 `game`，打开 `game120`，监听 `127.0.0.1:2528`。调用时用拼出来的名字：

```lua
local cluster = require "skynet.cluster"
cluster.call("game120", ".mail", ...)
```

`__nowaiting = true` 时，对方还没起来，`cluster.call` 会失败而不是一直等。再加服时，在 `clustername.lua` 加一行，并另起一个进程，改它的 `host_id` 和端口。`nodename` 保持 `game`。

---

## 数据与 ORM

持久化采用 **schema + OOP 行为分离**：

- **Schema**：`orm/schema/*.td` 描述可落库结构（`number` / `string` / `boolean` / `struct` / `list` / `map`）
- **核心库**：`lualib/orm`（`new` / `bind` / `get` / `unbind` / `touch` / `dump`）
- **游戏入口**：`Import("../orm/init.lua")` → 全局 `ORM`
- **行为类**：`clsUser` / `clsHero` 等通过 `self._data` 持有 ORM 对象，方法仍用 `clsObject:Inherit()`

约定：

1. Mongo 文档字段名只能是字符串；`map <number, …>` 的 key 在 **dump** 时转为字符串，**create** 时按 schema 还原为 number  
2. **不要**在 `$set` 路径中使用纯数字段（如 `dat.1001.xxx`）；用户英雄等挂在 `dat._heroes` 下整包更新  
3. 不兼容旧版 `@` 数字前缀存档；换库或清集合后使用  

加载或创建文档后绑上集合和 `_id`。之后改字段会标脏，刷盘时整包写回：

```lua
self._data = ORM.new(ORM.CLS_USER_DATA, oci)
ORM.bind(self._data, MONGO_SLAVE.COL.USER_INFO, self._data._user_id)
self._data._name = name
```

按 id 存一包子对象的文档（英雄、道具等）用 `ORM.load` 读取，子对象直接赋值挂上、赋 `nil` 删除：

```lua
local doc, is_loaded = ORM.load(MONGO_SLAVE.COL.USER_HERO, user_id, ORM.CLS_USER_HERO_DOC)
doc._heroes[hero_type] = ORM.new(ORM.CLS_HERO_DATA, oci)
doc._heroes[hero_type] = nil
```

新建文档如果之后没有赋值，调用 `ORM.touch(doc)` 标一次脏。下线时 `ORM.unbind(col, key)`。新增可存盘类型：先写 `orm/schema/xxx.td`，再在 `orm/init.lua` 的 `SCHEMA_FILES` 中注册。

普通属性变动在 50ms 窗口内合并，同一集合按最多 256 条、约 4MiB BSON 数据分批写入；同一文档的连续整包只保留最新一份，局部更新和删除仍保持原顺序。关键步骤和下线调用 `MONGO_SLAVE.flush_sync()` 等待数据库确认。写入失败会保留待写队列并重试，关服遇到失败会停在对应服务，恢复数据库后可再次执行 `shell/stop.sh`，不会继续关闭数据库后报告成功。待写队列仍在内存中，不能用强杀代替正常关服。

`find_all` 会读完所有游标批次；读取异常向调用方报错，不伪装成空存档。`common_load_many` 使用 `_id` 索引批量查询。地图启动仅读取主城坐标、名字等所需玩家字段。

世界、联盟和私聊的最近消息保存在 `chat_history_col`，每个会话按 `Global.Id=9` 保留条数，私聊按双方 uid 组成唯一会话键，复用 `_id` 索引。历史按需读取，数据库写入确认后才回成功和广播；消息编号使用持久化序列，重启不会从 1 开始。联盟解散时清理其聊天记录。此处保存的是近期聊天历史，不是无限期消息归档。

验证：`sh shell/test.sh` 检查语法和单元测试；`sh shell/test_db.sh` 复用本机连接配置，在独立测试库验证多批游标、批量更新、写入失败和聊天重连恢复，结束后清理测试库。修改数据库服务入口或关服逻辑后需正常重启服务。

---

## 开发指南

### 新增 Skynet 服务

1. 在 `logic/service/<name>/` 增加入口与 `CMD`  
2. `skynet.dispatch("lua", …)` 处理消息  
3. 在 `start_up/main_start.lua` 中 `newservice` / `call` 启动  

### 新增 Agent 玩法模块

1. 在 `logic/service/agent/module/<mod>/` 增加 `base.lua` / `mgr.lua`  
2. 在 `logic/service/agent/global.lua` 中 `Import` 挂到全局（如 `FOO_MGR = Import(...)`）  
3. 需要落库时：补 `.td` → `self._data` → `ORM.bind`。改字段即标脏  

### 进程间通信

| 场景 | API |
|------|-----|
| 需要返回值 | `skynet.call` |
| 单向通知 | `skynet.send` |
| 高频路径 | 避免同步打满 DB；批量或异步落盘 |

### 协议

- 包格式：`长度(2) + 协议ID(2) + protobuf`  
- 映射：`game_common/server/net_pb.lua`  
- `.pb` 文件：`game_common/pb/`  
- `.proto` 源文件：`game_common/proto/`  

---

## 脚本一览

| 脚本 | 作用 |
|------|------|
| `shell/build.sh` | 编译 Skynet、`protobuf.so`、`navigation/c.so`、`aoi/c.so` |
| `shell/start.sh` | 后台启动主节点，输出在 `log/skynet.log`；`-f` 前台 |
| `shell/stop.sh` | 安全关服：下线、落盘后进程自己退出 |
| `shell/restart.sh` | `stop.sh` 之后再 `start.sh`，参数透传（`-f`） |
| `shell/hot_update.sh` | 热更 lua 文件，`-c` 同时重载配置表 |
| `shell/runtest.sh` | 启动测试节点 |
| `shell/test.sh` | lua / shell 语法检查和单元测试，不需要起服 |
| `shell/test_db.sh` | 独立测试库中的真实 MongoDB 持久化集成测试 |
| `shell/bench.sh` | 机器人压测，`--relogin` 做顶号检查；结果在 `log/bench_result.txt` |
| `shell/start_db.sh` | 启动 MongoDB / Redis（`/usr/local` 模板路径，系统包安装可不用） |
| `shell/stop_db.sh` | 停止 DB（同样依赖模板路径） |
| `shell/drop_db.sh` | 清空业务库与 Redis（慎用） |

---

## 文档索引

| 文档 | 内容 |
|------|------|
| [FRAMEWORK_REVIEW.md](FRAMEWORK_REVIEW.md) | 架构评价与改进建议 |
| [PERFORMANCE_ANALYSIS.md](PERFORMANCE_ANALYSIS.md) | 性能与负载分析 |
| [docs/GATE_SCALING.md](docs/GATE_SCALING.md) | 网关扩展：进程内多 worker，以及还没做的跨进程方案 |
| [docs/地图构建流程.md](docs/地图构建流程.md) | `make map` 生成、校验、预览、差异比较与世界版本绑定 |

上游参考：[Skynet Wiki](https://github.com/cloudwu/skynet/wiki)

---

## 已知限制

- 读请求测到 1000 人同时在线没有压力；1000 人以上，以及建造、抽卡等写操作还没压。大型 MMO 还需补监控和工程化
- Redis 登录 token 默认约 **300s** 过期（以登录服实现为准）
- 网关的并行在单个进程内：`gate_cnt` 个 worker 分担读写。跨进程、跨机器的多网关还没做，见 `docs/GATE_SCALING.md`
- 热更替换的是函数。模块里的非函数值（常量、已初始化的表）保持旧值，改这些需要重启
- Cluster 已监听，玩法仍在同一进程；拆节点时再把对应服务挪出去

---

## License

本仓库代码可按 **MIT** 使用与修改；**Skynet** 及第三方组件请遵循其各自许可证。
