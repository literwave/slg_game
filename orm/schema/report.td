# report persist (agent USER_REPORT_COL.dat)
# 每个玩家一份，_reports 按战报 id 存，超出 CONST.REPORT_MAX 删最早的

# 兵力与部队一致：count 含伤兵，hurt 是其中的伤兵；怪物没有伤兵
report_unit {
    _pos number
    _cfg_id number
    _level number
    _before_count number
    _before_hurt number
    _after_count number
    _after_hurt number
}

report_unit_list [report_unit]

report_side {
    _owner_id number
    _name string
    _power number
    _units report_unit_list
}

replay_effect {
    _target_side number
    _target_pos number
    _value number
    _after_soldier number
    _flags number
}

replay_effect_list [replay_effect]

replay_action {
    _round number
    _act_type number
    _from_side number
    _from_pos number
    _skill_id number
    _effects replay_effect_list
}

replay_action_list [replay_action]

report_reward {
    _reward_type number
    _item_id number
    _item_count number
}

report_reward_list [report_reward]

report_data {
    _source_key string
    _report_id number
    _report_type number
    _target_type number
    _target_id number
    _result number
    _time number
    _is_read boolean
    _x number
    _y number
    _atk_side report_side
    _def_side report_side
    _rewards report_reward_list
    _max_round number
    _actions replay_action_list
}

report_bag <number, report_data>

user_report_doc {
    _reports report_bag
    _next_id number
}
