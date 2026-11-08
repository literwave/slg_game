local config = require "config_table"
local T = {}
function T.sparse_ids_and_arrays_keep_all_rows()
    local rows = {[1]={Id=1},[2]={Id=2},[21]={Id=21},[48]={Id=48}}
    local out=config.index_by_id(rows)
    assert(out[21] and out[48])
    out=config.index_by_id({{Id=20},{Id=50}})
    assert(out[20] and out[50])
    assert(not pcall(config.index_by_id,{{Id=1},{Id=1}}))
end
function T.authoritative_city_guards_are_all_loaded()
    local monster=config.index_by_id(dofile("game_common/server/res/Monster.lua"))
    local city=config.index_by_id(dofile("game_common/server/res/City.lua"))
    local count=0;for _ in pairs(monster) do count=count+1 end
    assert(count==38 and monster[24].Soldier==2340 and monster[48])
    config.validate_city_guards({Monster=monster,City=city})
    monster[24]=nil
    assert(not pcall(config.validate_city_guards,{Monster=monster,City=city}))
    assert(dofile("game_common/server/enum/TroopStateEnum.lua").SIEGE==4)
end
return T
