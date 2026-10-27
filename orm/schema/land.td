# 已被占领的地块。key = y * 1000 + x。中立地不落库
# 采空后地还在，_remain 归零，_refill_at 到点补回储量

land_data {
    _owner_id number
    _cfg_id number
    _remain number
    _troop_idx number
    _gather_end number
    _refill_at number
    _pending_owner number
    _occupy_end number
}
