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

function cls_hero:get_hero_pto_base_info()
	local skill_list = {}
	for skill_id, skill_lv in pairs(self._data._skill_tbl) do
		table.insert(skill_list, {
			k = skill_id,
			v = skill_lv,
		})
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
