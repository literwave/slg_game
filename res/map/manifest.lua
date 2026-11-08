-- 本目录 Lua 的 SHA256 与地图版本。服务端记录 mapRevision，不要和旧版点位混用。
-- 配置表 ResLand、ResLandType 由 game_common 的 server/res 提供，不在此包内。

return {
    ["schemaVersion"] = 2,
    ["mapRevision"] = "1c8ed4a2ba578b508fb3b83bff95e3d575ca453d59330258a14ea54413150d5e",
    ["width"] = 1000,
    ["height"] = 1000,
    ["topologyVersion"] = 2,
    ["cellIdFormula"] = "y * 1000 + x",
    ["listAccess"] = "list[cellId][1]=type, list[cellId][2]=level",
    ["fixedBirthResourceCount"] = 6069,
    ["fixedBirthLevels"] = {
4,5,6
},
    ["fixedInnerResourceCount"] = 658,
    ["resourceLayoutVersion"] = 3,
    ["files"] = {
        ["campaign-map.lua"] = "fa544536a0ecaea89fd27ecfb501137426935f4e4ff14be51f7cad6a199da309",
        ["mapRes_0.lua"] = "eeed8113f9b7b08794e842a027786a533878c1607ec88e61d7d69cd86fc95ccd",
        ["terrain.lua"] = "c2e2c39fa833b36e710d9422af2a5784d969b999d9790906dced429c024fde8d"
    }
}
