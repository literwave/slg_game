# server persist (activity service SERVER_COL.dat)
# 冲榜分数。排名在内存里用 zset 算，这里只存分数和达到该分数的时间（同分先到的靠前）
# 名字头像随分数一起由 agent 上报，排行榜列表直接用，不去读别人的玩家数据
# 开服时间不在这里，读节点配置 open_time

rank_entry {
    _score number
    _time number
    _name string
    _head_icon number
}

rank_map <number, rank_entry>

server_data {
    _power_tbl rank_map
    _city_tbl rank_map
    _kill_tbl rank_map
    _alliance_power_tbl rank_map
}
