local navigation = require "navigation"
local T = {}
local function signature(path)
    local out={tostring(path and #path or 0)}
    for _,pos in ipairs(path or {}) do out[#out+1]=string.format("%.6f,%.6f",pos[1],pos[2]) end
    return table.concat(out,";")
end
local function flood(blocked,w,h,sx,sy,ex,ey)
    local first,last=sy*w+sx,ey*w+ex
    if blocked[first] or blocked[last] then return false end
    local queue,seen,head={first},{[first]=true},1
    while head<=#queue do
        local key=queue[head];head=head+1
        if key==last then return true end
        local x,y=key%w,key//w
        for _,p in ipairs({{x-1,y},{x+1,y},{x,y-1},{x,y+1}}) do
            local nx,ny=p[1],p[2]
            if nx>=0 and ny>=0 and nx<w and ny<h then
                local n=ny*w+nx
                if not blocked[n] and not seen[n] then seen[n]=true;queue[#queue+1]=n end
            end
        end
    end
    return false
end
function T.repeated_native_search_matches_fresh_buffers_and_flood_fill()
    local seed=117
    local function rand(n) seed=(seed*48271)%2147483647;return seed%n end
    local w,h=63,47
    local obstacles,blocked={},{}
    for y=0,h-1 do for x=0,w-1 do
        if rand(100)<28 then blocked[y*w+x]=true;obstacles[#obstacles+1]={x,y} end
    end end
    local reused=navigation.new(w,h,obstacles)
    for query=1,240 do
        local sx,sy,ex,ey
        repeat sx,sy=rand(w),rand(h) until not blocked[sy*w+sx]
        repeat ex,ey=rand(w),rand(h) until not blocked[ey*w+ex]
        if query%7==0 then ex,ey=sx,sy end
        local fresh=navigation.new(w,h,obstacles)
        local path=reused.core:find_path(sx+.5,sy+.5,ex+.5,ey+.5)
        local reference=fresh.core:find_path(sx+.5,sy+.5,ex+.5,ey+.5)
        assert(signature(path)==signature(reference),"native search retained old scratch state at query "..query)
        assert((path and #path>0 or false)==flood(blocked,w,h,sx,sy,ex,ey),"reachability differs from flood fill")
    end
end
function T.reachable_unreachable_same_cell_and_native_errors_can_alternate()
    local obstacles={}
    for y=0,23 do if y~=12 then obstacles[#obstacles+1]={20,y} end end
    local nav=navigation.new(41,24,obstacles)
    for round=1,100 do
        assert(nav.core:find_path(2.5,12.5,38.5,12.5))
        nav:set_obstacle({x=20,y=12});nav:update_areas()
        assert(not nav.core:find_path(2.5,12.5,38.5,12.5))
        -- Exercise exhaustive JPS failure, not only the connectivity early return.
        nav:set_connected_id({x=38,y=12},nav:get_area_id_by_pos({x=2,y=12}))
        assert(not nav.core:find_path(2.5,12.5,38.5,12.5))
        assert(nav.core:find_path(2.5,12.5,5.5,15.5))
        local same=assert(nav.core:find_path(5.5,15.5,5.5,15.5))
        assert(#same==2 and same[1][1]==same[2][1] and same[1][2]==same[2][2])
        -- Unlike the float binding, the grid API enters JPS for start == end.
        local same_grid=assert(nav.core:find_path_by_grid(5,15,5,15,true))
        assert(#same_grid==1 and same_grid[1][1]==5 and same_grid[1][2]==15)
        assert(not pcall(nav.core.find_path,nav.core,-1,0,2,2))
        assert(not pcall(nav.core.find_path,nav.core,2,2,41,24))
        nav:unset_obstacle({x=20,y=12});nav:update_areas()
        assert(nav.core:find_path(38.5,12.5,2.5,12.5))
    end
end
return T
