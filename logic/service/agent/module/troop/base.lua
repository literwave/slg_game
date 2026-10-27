cls_troop = cls_object:Inherit()

function cls_troop:__init__(oci)
	Super(cls_troop).__init__(self, oci)
	self._data = ORM.new(ORM.CLS_TROOP_DATA, oci)
	ORM.get(MONGO_SLAVE.COL.USER_TROOP, self._data._user_id)._troops[self._data._troop_idx] = self._data
	TROOP_MGR.ref_troop(self)
end

function cls_troop:get_user_id()
	return self._data._user_id
end

function cls_troop:get_troop_idx()
	return self._data._troop_idx
end

function cls_troop:get_pos_tbl()
	return self._data._pos_tbl
end

function cls_troop:set_pos(pos, hero_idx, count, hurt)
	if not hero_idx then
		self._data._pos_tbl[pos] = nil
		return
	end
	self._data._pos_tbl[pos] = {
		_hero_idx = hero_idx,
		_soldier_cnt = count,
		_hurt_cnt = hurt,
	}
end

function cls_troop:clear_pos()
	local pos_list = {}
	for pos in pairs(self:get_pos_tbl()) do
		pos_list[#pos_list + 1] = pos
	end
	for _, pos in ipairs(pos_list) do
		self:set_pos(pos, nil)
	end
end

function cls_troop:get_soldier_sum()
	local sum = 0
	for _, info in pairs(self:get_pos_tbl()) do
		sum = sum + info._soldier_cnt
	end
	return sum
end

-- _soldier_cnt 是可用 + 伤兵。协议 p_soldier_info.count 只计可用兵力
function cls_troop:slot_healthy(info)
	local hurt = info._hurt_cnt
	local healthy = info._soldier_cnt - hurt
	if healthy < 0 then
		healthy = 0
	end
	return healthy, hurt
end

function cls_troop:has_hero()
	for _ in pairs(self:get_pos_tbl()) do
		return true
	end
	return false
end

function cls_troop:find_hero(hero_idx)
	for pos, info in pairs(self:get_pos_tbl()) do
		if info._hero_idx == hero_idx then
			return pos, info
		end
	end
end

function cls_troop:get_troop_state()
	return self._data._troop_state
end

function cls_troop:set_troop_state(state)
	self._data._troop_state = state
end

function cls_troop:get_march_state()
	return self._data._march._state
end

function cls_troop:get_target_type()
	return self._data._march._target_type
end

function cls_troop:get_target_id()
	return self._data._march._target_id
end

function cls_troop:get_start_time()
	return self._data._march._start_time
end

function cls_troop:get_end_time()
	return self._data._march._end_time
end

function cls_troop:is_marching()
	return self:get_march_state() ~= 0
end

function cls_troop:calc_pos(now)
	local march = self._data._march
	return MARCH_PATH.pos_at(march._path, march._start_time, march._end_time, now)
end

function cls_troop:set_march(info)
	local march = self._data._march
	march._state = info.state
	march._target_type = info.target_type
	march._target_id = info.target_id
	march._path = info.path
	march._start_time = info.start_time
	march._end_time = info.end_time
	if info.state == CONST.MARCH_STATE.MOVING then
		self:set_troop_state(DATA_COMMON.TROOP_STATE.MARCH)
	elseif info.state == 0 then
		self:set_troop_state(DATA_COMMON.TROOP_STATE.IN_CITY)
	end
end

function cls_troop:set_arrived()
	self._data._march._state = CONST.MARCH_STATE.ARRIVED
	self:set_troop_state(DATA_COMMON.TROOP_STATE.STAY)
end

-- 打赢后停在原地等占领倒计时。归属要到点才写入，这段时间部队状态仍是停留
function cls_troop:set_occupy_wait(start_time, end_time)
	local march = self._data._march
	march._state = CONST.MARCH_STATE.ARRIVED
	march._start_time = start_time
	march._end_time = end_time
	self:set_troop_state(DATA_COMMON.TROOP_STATE.STAY)
end

-- 占领资源地后停在原地采集，start/end 改记采集开始和采满的时间
function cls_troop:set_gather(start_time, end_time)
	local march = self._data._march
	march._state = CONST.MARCH_STATE.ARRIVED
	march._start_time = start_time
	march._end_time = end_time
	self:set_troop_state(DATA_COMMON.TROOP_STATE.GATHER)
end

function cls_troop:is_gathering()
	return self:get_troop_state() == DATA_COMMON.TROOP_STATE.GATHER
end

function cls_troop:get_end_pos()
	return MARCH_PATH.last_pos(self._data._march._path)
end

function cls_troop:clear_march()
	self:set_march({
		state = 0,
		target_type = 0,
		target_id = 0,
		path = {},
		start_time = 0,
		end_time = 0,
	})
end

function cls_troop:get_march_info()
	local march = self._data._march
	return {
		user_id = self:get_user_id(),
		troop_idx = self:get_troop_idx(),
		target_type = self:get_target_type(),
		target_id = self:get_target_id(),
		path = MARCH_PATH.copy(march._path),
		start_time = march._start_time,
		end_time = march._end_time,
	}
end

function cls_troop:get_march_pto()
	local march = self._data._march
	local sx, sy = MARCH_PATH.first_pos(march._path)
	local ex, ey = MARCH_PATH.last_pos(march._path)
	return {
		troopIdx = self:get_troop_idx(),
		targetType = self:get_target_type(),
		targetId = self:get_target_id(),
		startPos = {x = math.floor(sx), y = math.floor(sy)},
		endPos = {x = math.floor(ex), y = math.floor(ey)},
		startTime = march._start_time,
		endTime = march._end_time,
		state = self:get_march_state(),
		path = MARCH_PATH.to_pto(march._path),
	}
end

function cls_troop:get_pto_info()
	local pos_map = {}
	for pos, info in pairs(self:get_pos_tbl()) do
		pos_map[#pos_map + 1] = {
			key = pos,
			value = {
				heroIdx = info._hero_idx,
				soldier = {
					count = self:slot_healthy(info),
					hurtCount = info._hurt_cnt,
				},
			},
		}
	end
	return {
		troopIdx = self:get_troop_idx(),
		posMap = pos_map,
	}
end
