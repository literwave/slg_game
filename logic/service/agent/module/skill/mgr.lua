-- 玩家习得的战法。自带技在 Hero.SkillId，不进这个包，也不进武将协议的 skillList
-- 技能书（Item.Kind=10）获得时习得 1 级。装备次数受 Skill.Limit 限制。升级只升已装备的槽位

local function doc_of(user_id)
	return ORM.load(MONGO_SLAVE.COL.USER_SKILL, user_id, ORM.CLS_USER_SKILL_DOC)
end

local function is_learnable(skill_id)
	local conf = DATA_COMMON.get_skill_conf(skill_id)
	return conf and skill_id >= 2001
end

function slot_count()
	return CONST.SKILL_SLOT_COUNT
end

function get_level(user_id, skill_id)
	local lv = doc_of(user_id)._skills[skill_id]
	if not lv or lv < 1 then
		return 0
	end
	return lv
end

local function sync_skill(user_id, skill_id, lv)
	local fd = USER_MGR.get_fd_by_user_id(user_id)
	if not fd then
		return
	end
	for_caller.s2c_sync_skill_data(fd, {skillId = skill_id, skillLv = lv})
end

function learn(user_id, skill_id)
	if not is_learnable(skill_id) then
		return false
	end
	local doc = doc_of(user_id)
	if doc._skills[skill_id] and doc._skills[skill_id] >= 1 then
		return false
	end
	doc._skills[skill_id] = 1
	sync_skill(user_id, skill_id, 1)
	return true
end

function on_item_add(user_id, item_id)
	local conf = DATA_COMMON.get_item_conf(item_id)
	local params = conf and conf.useParams
	if not params then
		return
	end
	for _, param in ipairs(params) do
		if param.skill_id then
			learn(user_id, param.skill_id)
		end
	end
end

function grant_max_all(user_id)
	local doc = doc_of(user_id)
	for skill_id, conf in pairs(DATA_COMMON.get_skill_tbl()) do
		if is_learnable(skill_id) then
			local max_lv = #conf.Levels
			if max_lv < 1 then
				max_lv = 1
			end
			if doc._skills[skill_id] ~= max_lv then
				doc._skills[skill_id] = max_lv
				sync_skill(user_id, skill_id, max_lv)
			end
		end
	end
end

local function equipped_count(user_id, skill_id)
	local count = 0
	for _, hero in pairs(HERO_MGR.get_hero_tbl_by_user_id(user_id) or {}) do
		for pos = 0, CONST.SKILL_SLOT_COUNT - 1 do
			if hero:get_skill_slot(pos) == skill_id then
				count = count + 1
			end
		end
	end
	return count
end

local function hero_has_skill(hero, skill_id)
	for pos = 0, CONST.SKILL_SLOT_COUNT - 1 do
		if hero:get_skill_slot(pos) == skill_id then
			return pos
		end
	end
end

local function sync_heroes_with_skill(user_id, skill_id)
	for _, hero in pairs(HERO_MGR.get_hero_tbl_by_user_id(user_id) or {}) do
		if hero_has_skill(hero, skill_id) then
			hero:sync_to_client()
		end
	end
end

local function read_pos(packet)
	local pos = packet.pos or 0
	if pos < 0 or pos >= CONST.SKILL_SLOT_COUNT then
		return
	end
	return pos
end

local function on_req_all_skill_data(fd)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	if not user_id then
		return
	end
	local list = {}
	for skill_id, lv in pairs(doc_of(user_id)._skills) do
		if lv >= 1 then
			list[#list + 1] = {skillId = skill_id, skillLv = lv}
		end
	end
	for_caller.s2c_req_all_skill_data(fd, {skillList = list})
end

local function on_equip_skill(fd, packet)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	if not user_id then
		return
	end
	local hero = HERO_MGR.get_hero_by_type(user_id, packet.heroId)
	local skill_id = packet.skillId
	local pos = read_pos(packet)
	if not hero or not pos or not is_learnable(skill_id) then
		USER_MGR.tell_me(user_id, "技能不存在")
		return
	end
	if get_level(user_id, skill_id) < 1 then
		USER_MGR.tell_me(user_id, "尚未习得该技能")
		return
	end
	local owned_pos = hero_has_skill(hero, skill_id)
	if owned_pos and owned_pos ~= pos then
		USER_MGR.tell_me(user_id, "该技能已装备")
		return
	end
	if hero:get_skill_slot(pos) ~= skill_id then
		local conf = DATA_COMMON.get_skill_conf(skill_id)
		if equipped_count(user_id, skill_id) >= conf.Limit then
			USER_MGR.tell_me(user_id, "技能装备数量已达上限")
			return
		end
		hero:set_skill_slot(pos, skill_id)
		hero:sync_to_client()
	end
	for_caller.s2c_equip_skill(fd, {heroId = packet.heroId, skillId = skill_id, pos = pos})
end

local function on_unequip_skill(fd, packet)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	if not user_id then
		return
	end
	local hero = HERO_MGR.get_hero_by_type(user_id, packet.heroId)
	local pos = read_pos(packet)
	if not hero or not pos then
		USER_MGR.tell_me(user_id, "技能不存在")
		return
	end
	if hero:get_skill_slot(pos) ~= packet.skillId then
		USER_MGR.tell_me(user_id, "技能不在该槽位")
		return
	end
	hero:set_skill_slot(pos, nil)
	hero:sync_to_client()
	for_caller.s2c_unequip_skill(fd, {heroId = packet.heroId, skillId = packet.skillId, pos = pos})
end

local function on_upgrade_skill(fd, packet)
	local user_id = USER_MGR.get_user_id_by_fd(fd)
	if not user_id then
		return
	end
	local hero = HERO_MGR.get_hero_by_type(user_id, packet.heroId)
	local pos = read_pos(packet)
	if not hero or not pos then
		USER_MGR.tell_me(user_id, "该槽位没有技能")
		return
	end
	local skill_id = hero:get_skill_slot(pos)
	if not skill_id then
		USER_MGR.tell_me(user_id, "该槽位没有技能")
		return
	end
	local lv = get_level(user_id, skill_id)
	local max_lv = DATA_COMMON.get_skill_max_level(skill_id)
	if lv >= max_lv then
		USER_MGR.tell_me(user_id, "技能已满级")
		return
	end
	local new_lv = lv + 1
	doc_of(user_id)._skills[skill_id] = new_lv
	sync_skill(user_id, skill_id, new_lv)
	sync_heroes_with_skill(user_id, skill_id)
	for_caller.s2c_upgrade_skill(fd, {heroId = packet.heroId, pos = pos, skillLv = new_lv})
end

function on_user_logout(user_id)
	if ORM.get(MONGO_SLAVE.COL.USER_SKILL, user_id) then
		MONGO_SLAVE.flush()
		ORM.unbind(MONGO_SLAVE.COL.USER_SKILL, user_id)
	end
end

function __init__()
	for_maker.c2s_req_all_skill_data = on_req_all_skill_data
	for_maker.c2s_equip_skill = on_equip_skill
	for_maker.c2s_unequip_skill = on_unequip_skill
	for_maker.c2s_upgrade_skill = on_upgrade_skill
	EVENT.listen(CONST.EVENT.ON_USER_LOGOUT)
end
