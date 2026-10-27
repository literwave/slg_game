# hero persist schema (agent USER_HERO_COL.dat)
# 文档形状: { _heroes: { "hero_type": hero_data, ... } }
# map 的 number key 落库为字符串，加载时按类型还原，路径中不出现数字段

skill_map <number, number>
equip_map <number, number>

hero_data {
    _hero_type number
    _user_id number
    _exp number
    _level number
    _star number
    _equip_tbl equip_map
    _skill_tbl skill_map
    _skill_slot skill_map
    _new_tag boolean
    _state number
}

hero_bag <number, hero_data>

user_hero_doc {
    _heroes hero_bag
}
