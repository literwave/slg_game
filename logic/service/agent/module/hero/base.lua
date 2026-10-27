cls_hero = cls_object:Inherit()

function cls_hero:__init__(oci)
	Super(cls_hero).__init__(self, oci)
	self._data = ORM.new(ORM.CLS_HERO_DATA, oci)
	ORM.get(MONGO_SLAVE.COL.USER_HERO, self._data._user_id)._heroes[self._data._hero_type] = self._data
end

function cls_hero:get_user_id()
	return self._data._user_id
end

function cls_hero:get_new_tag()
	return self._data._new_tag
end

function cls_hero:set_new_tag(new_tag)
	self._data._new_tag = new_tag and true or false
end

function cls_hero:get_hero_type()
	return self._data._hero_type
end

function cls_hero:get_star()
	return self._data._star
end

function cls_hero:get_level()
	return self._data._level
end

function cls_hero:set_level(level)
	if self._data._level == level then
		return
	end
	self._data._level = level
	self._data._exp = 0
	EVENT.dispatch(CONST.EVENT.ON_HERO_LEVEL, self:get_user_id(), self:get_hero_type())
end

function cls_hero:get_skill_slot(pos)
	return self._data._skill_slot[pos]
end

function cls_hero:set_skill_slot(pos, skill_id)
	self._data._skill_slot[pos] = skill_id
end

-- 自带技不进协议，等级固定 1。已装备的可学战法按槽位带上技能包里的等级
function cls_hero:get_battle_skills()
	local list = {}
	local conf = DATA_COMMON.get_hero_info_by_type(self:get_hero_type())
	local innate = conf and conf.SkillId
	if innate and innate > 0 then
		list[#list + 1] = {id = innate, lv = 1}
	end
	local user_id = self:get_user_id()
	for pos = 0, CONST.SKILL_SLOT_COUNT - 1 do
		local skill_id = self:get_skill_slot(pos)
		if skill_id and skill_id > 0 and skill_id ~= innate then
			local lv = SKILL_MGR.get_level(user_id, skill_id)
			if lv < 1 then
				lv = 1
			end
			list[#list + 1] = {id = skill_id, lv = lv}
		end
	end
	return list
end

function cls_hero:get_hero_pto_base_info()
	local skill_list = {}
	local user_id = self:get_user_id()
	for pos = 0, CONST.SKILL_SLOT_COUNT - 1 do
		local skill_id = self:get_skill_slot(pos)
		if skill_id and skill_id > 0 then
			local lv = SKILL_MGR.get_level(user_id, skill_id)
			skill_list[#skill_list + 1] = {
				k = skill_id,
				v = lv > 0 and lv or 1,
			}
		end
	end
	return {
		heroId = self._data._hero_type,
		exp = self._data._exp,
		lv = self._data._level,
		star = self:get_star(),
		skillList = skill_list,
		newTag = self:get_new_tag(),
	}
end

function cls_hero:sync_to_client()
	local fd = USER_MGR.get_fd_by_user_id(self:get_user_id())
	for_caller.s2c_sync_hero_base_info(fd, {heroInfo = self:get_hero_pto_base_info()})
end

function cls_hero:get_skill_tbl()
	return self._data._skill_tbl
end

function cls_hero:set_skill_lv(skill_id, skill_lv)
	self._data._skill_tbl[skill_id] = skill_lv
end

function cls_hero:get_equip_tbl()
	return self._data._equip_tbl
end
