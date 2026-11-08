# mail persist（mail 服务）
# 每个玩家一份 user_mail_doc，_mails 按 mailUid 存；单类型超过 Global 15 删最早的
# 全服邮件存一份 svr_mail_doc，按序号存；玩家 _fetch_idx 之后的、没过期的登录时补发

mail_detail_list [string]

mail_reward {
    _reward_type number
    _item_id number
    _item_count number
}

mail_reward_list [mail_reward]

mail_data {
    _mail_uid number
    _mail_id number
    _mail_kind number
    _details mail_detail_list
    _rewards mail_reward_list
    _start_time number
    _end_time number
    _is_read boolean
    _is_got_reward boolean
    _is_lock boolean
}

mail_bag <number, mail_data>
mail_source_rounds <string, number>

user_mail_doc {
    _mails mail_bag
    _next_uid number
    _fetch_idx number
    _source_rounds mail_source_rounds
    _source_mail_ids mail_source_rounds
}

svr_mail {
    _mail_id number
    _details mail_detail_list
    _rewards mail_reward_list
    _start_time number
    _end_time number
}

svr_mail_bag <number, svr_mail>

svr_mail_doc {
    _mails svr_mail_bag
    _next_idx number
}
