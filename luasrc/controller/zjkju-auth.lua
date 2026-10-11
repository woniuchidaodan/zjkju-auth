module("luci.controller.zjkju-auth", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/zjkju-auth") then
		return
	end

	entry({"admin", "services", "zjkju-auth"},
		cbi("zjkju-auth/main"),
		_("ZJKJU 校园网认证"), 60).dependent = true

	entry({"admin", "services", "zjkju-auth", "log"},
		call("action_get_log")).leaf = true

	entry({"admin", "services", "zjkju-auth", "restart"},
		call("action_restart")).leaf = true

	entry({"admin", "services", "zjkju-auth", "clearlog"},
		call("action_clear_log")).leaf = true

	entry({"admin", "services", "zjkju-auth", "status"},
		call("action_status")).leaf = true
end

function action_get_log()
	local sys = require "luci.sys"
	local log = sys.exec("logread -e zjkju-auth 2>/dev/null | tail -100")
	if not log or log == "" then
		log = "（暂无日志，服务可能还未启动过）"
	end
	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.http.write(log)
end

function action_restart()
	local sys = require "luci.sys"
	sys.call("/etc/init.d/zjkju-auth restart >/dev/null 2>&1")
	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.http.write("服务已重启")
end

function action_clear_log()
	local sys = require "luci.sys"
	sys.call("/etc/init.d/log restart >/dev/null 2>&1 &")
	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.http.write("日志已清空")
end

function action_status()
	local sys = require "luci.sys"

	local running = false
	local pid = sys.exec("pidof zjkju-auth-wrapper.sh 2>/dev/null")
	if not pid or pid:gsub("%s+", "") == "" then
		pid = sys.exec("pidof zjkju-auth-wrapper 2>/dev/null")
	end
	if pid and pid:gsub("%s+", "") ~= "" then
		running = true
	end

	local online = false
	local body = sys.exec("/usr/bin/curl -s --max-time 5 'http://www.msftconnecttest.com/connecttest.txt' 2>/dev/null")
	if body then
		body = body:gsub("%s+", "")
		if body:find("MicrosoftConnectTest", 1, true) then
			online = true
		end
	end

	luci.http.prepare_content("application/json; charset=utf-8")
	luci.http.write_json({
		running = running,
		online = online,
		ts = os.time()
	})
end
