local skynet = require "skynet"
local mysql = require "skynet.db.mysql"

local tunpack = table.unpack

local ACTOR_VARIES = {
	{actor_id = "bigint"},
	{static_var = "longtext"},
	{login_time = "bigint"},
	{day_online_time = "bigint"},
}

local ACOTOR_BAG ={
	{actor_id = "bigint"},
	{bag_var = "longtext"},
}

function modify_actor_table()
	local db_etc = load("return "..skynet.getenv "db_info")()
	local function on_connect(db)
	   db:query("set charset utf8");
	 end
	local db=mysql.connect({
	     host=db_etc[1],
	     port=tonumber(db_etc[2]),
	     database=db_etc[3],
	     user=db_etc[4],
	     password=db_etc[5],
	     max_packet_size = 1024 * 1024,
	     on_connect = on_connect
	 })
	 if not db then
	       skynet.error("failed to connect mysql")
	       return
	 end
	 local sql = "desc actors;"
	 local result = db:query(sql) 
	 -- 如果表不存在就建�?
	 if result["badresult"] then
	    local tem_list = {}
	    for i = #ACTOR_VARIES ,1 , -1 do
	        LOG._debug(ACTOR_VARIES[i])
	        local column, column_type = tunpack(ACTOR_VARIES[i])
	        table.insert(tem_list, column .. " "..column_type)
	    end
	    sql = "create table actors (" .. table.concat(tem_list,",").. ") charset 'utf8';"
	    db:query(sql) 
	    sql = "alter table actors add primary key(actor_id)"
	    db:query(sql) 
	 end
	 -- 关闭数据�?
	 db:disconnect()
	--  待调整表的列
	--  local modify_columns
	--  for column, column_type in pairs(ACTOR_VARIES) do
	    
	    
	--  end
end

