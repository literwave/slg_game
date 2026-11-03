# 编译 Skynet（submodule）、pbc protobuf.so、slg-navigation、cloudwu/aoi、xjdrew/lua-zset

.PHONY: all linux macosx skynet protobuf navigation aoi zset clean

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  PLAT ?= macosx
  SHARED ?= -fPIC -dynamiclib -Wl,-undefined,dynamic_lookup
else
  PLAT ?= linux
  SHARED ?= -fPIC -shared
endif

CC ?= gcc
CFLAGS ?= -O2 -g -Wall

PBC_DIR := vendor/pbc
LUA_INC := skynet/3rd/lua
LUACLIB := skynet/luaclib
PROTOBUF_SO := $(LUACLIB)/protobuf.so

NAV_DIR := vendor/slg-navigation
NAV_SO := $(LUACLIB)/navigation/c.so
NAV_SRC := $(NAV_DIR)/luabinding.c $(NAV_DIR)/map.c $(NAV_DIR)/jps.c \
	$(NAV_DIR)/fibheap.c $(NAV_DIR)/smooth.c

AOI_DIR := vendor/aoi
AOI_SO := $(LUACLIB)/aoi/c.so
AOI_SRC := lualib/aoi_binding.c $(AOI_DIR)/aoi.c

ZSET_DIR := vendor/lua-zset
ZSET_SO := $(LUACLIB)/skiplist/c.so
ZSET_SRC := $(ZSET_DIR)/lua-skiplist.c $(ZSET_DIR)/skiplist.c

PBC_SRC := $(wildcard $(PBC_DIR)/src/*.c)
PBC_LUA := $(PBC_DIR)/binding/lua53/pbc-lua53.c

all: skynet protobuf navigation aoi zset

linux macosx:
	$(MAKE) all PLAT=$@

skynet:
	$(MAKE) -C skynet $(PLAT)

protobuf: $(PROTOBUF_SO)

$(PROTOBUF_SO): $(PBC_SRC) $(PBC_LUA)
	mkdir -p $(LUACLIB)
	$(CC) $(CFLAGS) $(SHARED) -o $@ $(PBC_SRC) $(PBC_LUA) \
		-I$(PBC_DIR) -I$(PBC_DIR)/src -I$(LUA_INC)

navigation: $(NAV_SO)

$(NAV_SO): $(NAV_SRC)
	mkdir -p $(LUACLIB)/navigation
	$(CC) $(CFLAGS) $(SHARED) -o $@ $(NAV_SRC) -I$(NAV_DIR) -I$(LUA_INC)

aoi: $(AOI_SO)

$(AOI_SO): $(AOI_SRC) $(AOI_DIR)/aoi.h
	mkdir -p $(LUACLIB)/aoi
	$(CC) $(CFLAGS) $(SHARED) -o $@ $(AOI_SRC) -I$(AOI_DIR) -I$(LUA_INC)

zset: $(ZSET_SO)

$(ZSET_SO): $(ZSET_SRC) $(ZSET_DIR)/skiplist.h
	mkdir -p $(LUACLIB)/skiplist
	$(CC) $(CFLAGS) $(SHARED) -o $@ $(ZSET_SRC) -I$(ZSET_DIR) -I$(LUA_INC) -lm

clean:
	-$(MAKE) -C skynet cleanall
	rm -f $(PROTOBUF_SO) $(NAV_SO) $(AOI_SO) $(ZSET_SO)

# 静态地图工具。环境变量直接传给 Python，避免拼接命令行参数。
# 默认只生成 build/maps/ 候选包，不改 res/map，不启动或重置世界。
PYTHON ?= python3
OUT ?= build/maps
CLIENT_REPO ?= git@github.com:literwave/slg_game_client.git
CLIENT_REF ?= master
# SEED/PROFILE 仅为拒绝旧用法而转交，工具不再支持随机生成或后端地图副本。
export CLIENT_REPO CLIENT_REF OUT MAP FROM TO SERVER_MAP SEED PROFILE CLIENT
.PHONY: map map-check map-check-server map-diff map-test

map:
	$(PYTHON) tools/world/map.py build

map-check:
	$(PYTHON) tools/world/map.py check

map-check-server:
	$(PYTHON) tools/world/map.py verify-server

map-diff:
	$(PYTHON) tools/world/map.py diff

map-test:
	$(PYTHON) -m unittest discover -s tools/world/tests -v
	$(LUA_INC)/lua test/unit/run.lua test/unit/test_world_map_package.lua
