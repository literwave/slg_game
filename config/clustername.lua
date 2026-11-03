-- Skynet cluster 节点表。每个服一行，端口不能重复。
-- 键是配置里的 nodename 拼上 host_id，例如 game 和 120 得到 game120。
-- __nowaiting：对方还没起来时，cluster.call 直接失败，不卡住启动。
__nowaiting = true

center0 = "127.0.0.1:2527"
game120 = "127.0.0.1:2528"
