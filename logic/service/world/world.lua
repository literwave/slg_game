local skynet = require "skynet"
require "skynet.manager"

local CMD = {}

function CMD.shutdown()
	MONGO_SLAVE.flush_sync()
	skynet.fork(skynet.exit)
end

function CMD.performance_stats()
    local stats = AOI_MGR.performance_stats()
    if stats.enabled then stats.navigation = MAP_MGR.navigation_stats() end
    return stats
end

function CMD.hot_update(_, path_list)
	return hot_update(path_list)
end

function CMD.sync_to_map(oci)
	ENTITY_MGR.sync_to_map(oci)
end

function CMD.alloc_birth_pos()
	return MAP_MGR.alloc_birth_pos()
end

function CMD.upsert_city(_, user_id, x, y, info)
	AOI_MGR.upsert_city(user_id, x, y, info)
end

function CMD.move_city(_, user_id, x, y, old_x, old_y, info)
	if not MAP_MGR.relocate_birth(old_x, old_y, x, y) then
		return false
	end
	AOI_MGR.upsert_city(user_id, x, y, info)
	return true
end

function CMD.find_march_path(_, user_id, sx, sy, ex, ey)
	return MAP_MGR.find_march_path(user_id, sx, sy, ex, ey)
end

function CMD.req_city_list()
	return CITY_MGR.list()
end

function CMD.req_city_info(_, id)
	return CITY_MGR.info(id)
end

function CMD.city_target(_, id, uid)
	return CITY_MGR.target(id, uid)
end

function CMD.redeploy_target(_, id, uid)
    return CITY_MGR.redeploy_target(id, uid)
end

function CMD.find_redeploy_path(_, uid, sx, sy, id, round)
    local city = CITY_MGR.redeploy_target(id, uid, round)
    if not city then return end
    return MAP_MGR.find_march_path(uid, sx, sy, city.x, city.y)
end

function CMD.arrive_redeploy(_, info)
    local ok = CITY_MGR.arrive_redeploy(info)
    if ok then
        local x, y = MARCH_PATH.last_pos(info.path)
        AOI_MGR.park_troop(info.user_id, info.troop_idx, x, y, info.serial)
    end
    return ok
end

function CMD.find_city_march_path(_, uid, sx, sy, id)
	local city = CITY_MGR.target(id, uid)
	if not city then return end
	return MAP_MGR.find_city_approach(uid, sx, sy, city)
end

function CMD.find_march_route(_, uid, sx, sy, ex, ey, target_type)
	if target_type == DATA_COMMON.TARGET_TYPE.ATTACK_CITY then
		local city = CITY_MGR.target_at(ex, ey, uid)
		if not city then return end
		return MAP_MGR.find_city_approach(uid, sx, sy, city)
	end
    if target_type == DATA_COMMON.TARGET_TYPE.REDEPLOY and not CITY_MGR.redeploy_target_at(ex, ey, uid) then return end
	return MAP_MGR.find_march_path(uid, sx, sy, ex, ey)
end

function CMD.attack_city(_, id, actor)
	return CITY_MGR.attack(id, actor)
end

function CMD.ack_city_attack(_, id, uid, troop_idx, seq)
	return CITY_MGR.ack(id, uid, troop_idx, seq)
end

function CMD.get_march_path(_, user_id, entity_id)
	return AOI_MGR.get_march_path(user_id, entity_id)
end

function CMD.set_user_alliance(_, user_id, alliance_id)
	ENCOUNTER_MGR.set_user_alliance(user_id, alliance_id)
	CITY_MGR.on_user_alliance(user_id, alliance_id)
end

function CMD.start_march(_, info)
    if info.target_type == DATA_COMMON.TARGET_TYPE.REDEPLOY
        and not CITY_MGR.redeploy_target(info.target_id, info.user_id, info.redeploy_round) then return false end
    local ok = AOI_MGR.start_march(info)
    if ok then CITY_MGR.leave_redeploy(info.user_id, info.troop_idx) end
    return ok
end

function CMD.siege_troop(_, info)
    local city = CITY_MGR.info(info.target_id)
    return AOI_MGR.siege_troop(info, city and city.cityInfo and city.cityInfo.pos)
end

function CMD.park_troop(_, user_id, troop_idx, x, y)
	AOI_MGR.park_troop(user_id, troop_idx, x, y)
end

function CMD.hide_troop(_, user_id, troop_idx)
	AOI_MGR.hide_troop(user_id, troop_idx)
	CITY_MGR.leave_redeploy(user_id, troop_idx)
end

function CMD.remove_troop(_, user_id, troop_idx)
	AOI_MGR.remove_troop(user_id, troop_idx)
	CITY_MGR.leave_redeploy(user_id, troop_idx)
end

function CMD.monster_pos(_, entity_id)
	return AOI_MGR.monster_pos(entity_id)
end

function CMD.kill_monster(_, entity_id)
	return AOI_MGR.kill_monster(entity_id)
end

function CMD.res_land_info(_, entity_id)
	return LAND_MGR.info(entity_id)
end

function CMD.land_hostile(_, user_a, user_b)
	return ENCOUNTER_MGR.is_hostile(user_a, user_b)
end

function CMD.occupy_res_land(_, entity_id, user_id, troop_idx)
	return LAND_MGR.occupy(entity_id, user_id, troop_idx)
end

function CMD.leave_res_land(_, entity_id, user_id, troop_idx, gathered)
	return LAND_MGR.leave(entity_id, user_id, troop_idx, gathered)
end

function CMD.aoi_focus(_, user_id, x, y)
	return AOI_MGR.focus(user_id, x, y)
end

skynet.start(function()
	LOG._debug("boot world success")
	dofile "../logic/service/world/preload.lua"
	skynet.dispatch("lua", function (session, address, cmd, ...)
		local f = CMD[cmd]
		if f then
			if session ~= 0 then
				skynet.ret(skynet.pack(f(address, ...)))
			else
				f(address, ...)
			end
		end
	end)
	skynet.register(".world")
end)
