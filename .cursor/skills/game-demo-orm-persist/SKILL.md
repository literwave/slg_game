---
name: game-demo-orm-persist
description: >-
  Guides Game Demo Framework ORM schema, Mongo persistence, and gameplay Lua style.
  Server repo is slg_game; the client project is slg_game_client (Cocos Creator).
  Use when adding/changing .td schemas, clsXxx _data, saveDoc/saveDocField,
  mongo_slave persist, migrating modules off opMongoValue/@ paths, or writing
  game logic that checks or sends protocol fields for user, hero, item, build,
  troop, march, world, battle, report, task, activity, rank, mail, alliance,
  chat, or lottery. Protocol files live in the game_common submodule and must
  be pulled, not edited here.
---

# Game Demo ORM 存盘

## 项目与模块

服务端是本仓库 `slg_game`。客户端项目是 [slg_game_client](https://github.com/literwave/slg_game_client)（Cocos Creator 3.8.8）。协议和导表在子模块 `game_common`，客户端读同一份协议，不要在这边改。

玩家协议进 `logic/service/agent`。`global.lua` 里挂上的模块才生效。

| 模块 | 全局 | 功能 | 协议 |
|------|------|------|------|
| `module/user` | `USER_MGR` | 登录后的玩家档案、心跳、创角、迁城、头像、预备兵 | `User`：`c2s_user_base_info`、`c2s_user_create`、`c2s_move_city`、`c2s_change_head_icon`、`c2s_heart_beat`、`c2s_client_load_ok` |
| `module/resource` | `RESOURCE` | 资源栏查询（粮、水、木、石） | `User.c2s_req_user_res` |
| `module/hero` | `HERO_MGR` | 武将 | `c2s_req_all_hero_base_info` |
| `module/item` | `ITEM_MGR` | 道具、武将装备。建造和发奖来扣加，没有独立协议 | — |
| `module/build` | `BUILD_MGR` | 内城建筑：建造、升级 | `Build` |
| `module/troop` | `TROOP_MGR` | 编队。`count` 是可用兵力，伤兵跟着武将 | `World`：`c2s_req_troop`、`c2s_edit_troop` |
| `module/march` | `MARCH_MGR` | 出征、回城、采集结算；视野焦点转到 `.world` | `World`：`c2s_march`、`c2s_cancel_march`、`c2s_req_march_list`、`c2s_aoi_focus` |
| `module/battle` | `BATTLE_MGR` | 打野、占资源地、同格战的结算和发奖。伤害计算丢给 `.battle` | `Battle.c2s_battle_skip` |
| `module/report` | `REPORT_MGR` | 战报列表、详情、回放 | `Report` |
| `module/task` | `TASK_MGR` | 任务进度和领奖 | `Task` |
| `module/activity` | `ACTIVITY_MGR` | 活动列表；冲榜分数报到 `.activity` | `Activity`、`Rank.c2s_req_rank_list` |
| `module/lottery` | `LOTTERY` | 抽卡 | `c2s_req_user_lottery_info`、`c2s_user_lottery` |
| `module/reward` | `REWARD_MGR` | 发奖：道具、资源、武将、兵。超额道具走补发邮件 | — |
| `module/system_open` | `SYSTEM_OPEN` | 功能开启 | `c2s_req_system_open` |
| `module/mail` | `MAIL_MGR` | 协议转到 `.mail`；领奖在 agent 发 | `Mail` |
| `module/social` | `SOCIAL_MGR` | 协议转到 `.union`，带上玩家名片 | `Alliance`、`Chat` |
| `module/gm` | `GM` | GM | `User.c2s_gm_command` |

`module/queue`（建造队列）还没在 `global.lua` 挂上，协议未接入。

玩家数据以外的服务：

| 服务 | 功能 |
|------|------|
| `logind` | 账号登录，签发 token。客户端先连这里 |
| `gated` / `gate_worker` | 网关接入、校验 token、把包转到 agent |
| `world` | 大地图、出生点、寻路（`map`）、视野（`aoi`）、主城实体（`entity`）、同格遭遇（`encounter`）、资源地占领 |
| `battle` | 只算战斗，不存盘。同一目标固定进同一个服务 |
| `mail` | 邮件存取。领奖回 agent |
| `union` | 联盟存盘（`alliance`）；聊天只在内存（`chat`），重启清空 |
| `activity` | 战力榜、主城等级榜 |
| `gameserver` | 全局协调 |
| `game_sid` | 分配玩家 id |
| `main_mongodb` | Mongo 访问 |

## 原则

- **OOP 管行为**（`clsObject:Inherit()`），**ORM 管可落库数据**（`self._data`）
- Mongo 路径**禁止**纯数字段；**禁止** `@` 前缀
- `map <number, …>`：内存 number key，`ORM.dump` 转字符串，加载按 schema 还原

## 新增可存盘模块

1. 在 `orm/schema/<name>.td` 写类型（原子类型用 `number` / `string` / `boolean`）
2. 若有「id 当 key 的包」，用命名字段挂 map，例如 `_items` / `_heroes` / `_queues`
3. 把文件名加入 `orm/init.lua` 的 `SCHEMA_FILES`，并导出 `CLS_*` 常量。被引用的类型要写在引用者前面
4. `clsXxx:__init__`：`self._data = ORM.new(CLS_*, oci)`（oci 已是该类型 orm 对象时原样返回）
5. mgr 加载用 `local doc, is_loaded = ORM.load(MONGO_SLAVE.COL.XXX, id, CLS_*_DOC)`，`is_loaded` 为 true 时遍历 bag 建对象。集合名只用 `logic/base/mongo_slave.lua` 里的 `COL` 枚举。子对象在 `__init__` 里直接赋值挂进文档：`ORM.get(col, id)._heroes[k] = self._data`，删除赋 `nil`。不要在模块里再存一份 doc 表。改字段会把根标脏，`flush` 整包写回；下线 `ORM.unbind(col, id)`
6. 不要再写 `save_col.lua`、`persist*` 或在 setter 里 `saveField`。删整份独立文档仍用 `delDoc`

## 协议

- 不改 `game_common` 里的协议。`.proto`、`.pb`、`net_pb.lua`，以及 `ptotools` 下的协议描述，都不要在这个仓库里改
- 协议只通过子模块拉取：`git submodule update --init --remote game_common`。不要不带路径的 `--remote`，那会把 `skynet` 拉离开钉住的版本
- 业务可以先加字段。存盘 schema、对象的 getter/setter、发给客户端的 table 里可以先写上新字段。子模块的 pb 还没有该字段时，编码会报未知字段；等协议仓库提交后再拉取，不要为了能发出去去改 pb

## 禁止

- `opMongoValue` / `string.format("@%s", field)` / `removePreString`
- `$set` 路径形如 `dat.1001.xxx` 或 `dat.@1001.xxx`
- 把玩法方法挂到 orm 对象上，或用 orm 替换 `clsObject`
- 不要用 `type()` 判断一个变量的类型。协议字段和配置值按约定直接用，范围判断写 `pos < 1` 这种比较即可

## 参考形状

```text
UserItemDoc { _items <number, ItemData> }
UserHeroDoc { _heroes <number, HeroData> }
UserQueueDoc { _queues <number, QueueData> }
UserBuildDoc { _builds <number, BuildData> }
```

核心库：`lualib/orm`；游戏入口：`Import("../orm/init.lua")` → `ORM`。
落库：`ORM.bind` 之后标脏，由 `logic/base/mongo_slave.lua` 刷出。
