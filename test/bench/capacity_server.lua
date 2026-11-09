local skynet = require "skynet"
skynet.start(function()
    skynet.newservice("main_start")
    skynet.newservice("capacity_probe")
    skynet.exit()
end)
