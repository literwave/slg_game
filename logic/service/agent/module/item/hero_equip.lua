cls_item = CLS_BASE_ITEM.cls_item:Inherit()

function cls_item:__init__(oci)
	Super(cls_item).__init__(self, oci)
end

function cls_item:set_put_on_hero_type(hero_type)
	self._data._put_on_hero_type = hero_type or 0
end

function cls_item:get_put_on_hero_type()
	local v = self._data._put_on_hero_type
	if v == 0 then
		return nil
	end
	return v
end

function cls_item:get_strengthen_lv()
	return self._data._strengthen_lv
end

function cls_item:set_strengthen_lv(strengthen_lv)
	self._data._strengthen_lv = strengthen_lv
end

function cls_item:get_strengthen_exp()
	return self._data._strengthen_exp
end

function cls_item:set_strengthen_exp(strengthen_exp)
	self._data._strengthen_exp = strengthen_exp
end

function cls_item:get_forge_lv()
	return self._data._forge_lv
end

function cls_item:set_forge_lv(forge_lv)
	self._data._forge_lv = forge_lv
end

function cls_item:get_lv()
	return self._data._strengthen_lv
end

function cls_item:get_power()
	local strengthen_power = DATA_COMMON.get_item_strengthen_power(self:get_strengthen_lv(), self:get_equip_quality()) or 0
	local forge_power = DATA_COMMON.get_item_forge_power(self:get_forge_lv()) or 0
	return strengthen_power + forge_power
end

function cls_item:get_att()
	local base_att = DATA_COMMON.get_item_att(self:get_item_id()) or 0
	local level_att = DATA_COMMON.get_item_level_att(self:get_item_id(), self:get_strengthen_lv()) or 0
	local forge_add = DATA_COMMON.get_item_forge_grade_att(self:get_forge_lv()) or 0
	return (base_att + level_att) * (1 + forge_add)
end

function cls_item:get_def()
	local base_def = DATA_COMMON.get_item_def(self:get_item_id()) or 0
	local level_def = DATA_COMMON.get_item_level_def(self:get_item_id(), self:get_strengthen_lv()) or 0
	local forge_add = DATA_COMMON.get_item_forge_grade_att(self:get_forge_lv()) or 0
	return (base_def + level_def) * (1 + forge_add)
end

function cls_item:get_life()
	local base_life = DATA_COMMON.get_item_life(self:get_item_id()) or 0
	local level_life = DATA_COMMON.get_item_level_life(self:get_item_id(), self:get_strengthen_lv()) or 0
	local forge_add = DATA_COMMON.get_item_forge_grade_att(self:get_forge_lv()) or 0
	return (base_life + level_life) * (1 + forge_add)
end

function cls_item:get_lethality()
	local base_lethality = DATA_COMMON.get_item_lethality(self:get_item_id()) or 0
	local level_lethality = DATA_COMMON.get_item_level_lethality(self:get_item_id(), self:get_strengthen_lv()) or 0
	local forge_add = DATA_COMMON.get_item_forge_grade_att(self:get_forge_lv()) or 0
	return (base_lethality + level_lethality) * (1 + forge_add)
end

function cls_item:get_equip_quality()
	return DATA_COMMON.get_equip_quality(self:get_item_id())
end
