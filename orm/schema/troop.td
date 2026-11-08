# troop persist (agent USER_TROOP_COL.dat)
# pos_map: 站位 -> 英雄与带兵。_soldier_cnt = 可用 + 伤兵，_hurt_cnt = 伤兵
# _troop_state: TroopState.Enum。IN_CITY 在城，MARCH 行军，STAY 停留，GATHER 采集，SIEGE 攻城中。行军中的回城看 _march._target_type
# _march._path: 行军拐点（world 寻路结果，含起点和终点），起止坐标取首尾
# _march._state: 1行军中 2已到达。在城里时为 0

pos_info {
    _hero_idx number
    _soldier_cnt number
    _hurt_cnt number
}

pos_map <number, pos_info>

march_point {
    _x number
    _y number
}

march_path [march_point]

march_data {
    _state number
    _target_type number
    _target_id number
    _path march_path
    _start_time number
    _end_time number
}

troop_data {
    _user_id number
    _troop_idx number
    _pos_tbl pos_map
    _troop_state number
    _march march_data
    _march_serial number
    _siege_city number
    _siege_seq number
    # 本次出征锁定的城池归属轮次；被任何同盟攻下后停止原攻城指令
    _siege_round number
    # 调动锁定的归属轮次，防止旧行军在城池易主后重新登记驻留
    _redeploy_round number
}

troop_bag <number, troop_data>

user_troop_doc {
    _troops troop_bag
}
