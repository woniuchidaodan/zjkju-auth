module("luci.controller.zjkju-auth", package.seeall)

local LOG_FILE = "/var/log/zjkju-auth.log"
local STATUS_FILE = "/tmp/zjkju-auth-status"

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
	local http = require "luci.http"
	local fs = require "nixio.fs"

	http.prepare_content("text/plain; charset=utf-8")

	if not fs.access(LOG_FILE) then
		http.write("（暂无日志，服务可能还未启动过）")
		return
	end

	local data = fs.readfile(LOG_FILE) or ""
	if data == "" then
		http.write("（日志文件为空）")
		return
	end

	if #data > 100 * 1024 then
		data = data:sub(-(100 * 1024))
		local nl = data:find("\n")
		if nl then data = data:sub(nl + 1) end
	end

	local lines = {}
	for line in (data .. "\n"):gmatch("(.-)\n") do
		if line ~= "" then lines[#lines + 1] = line end
	end

	local start = math.max(1, #lines - 100 + 1)
	local buf = {}
	for i = start, #lines do buf[#buf + 1] = lines[i] end

	http.write(table.concat(buf, "\n"))
end

function action_restart()
	local sys = require "luci.sys"
	sys.call("/etc/init.d/zjkju-auth restart >/dev/null 2>&1")
	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.http.write("服务已重启")
end

function action_clear_log()
	local http = require "luci.http"
	local fs = require "nixio.fs"

	fs.writefile(LOG_FILE, "")

	http.prepare_content("application/json")
	http.write('{"ok":true}')
end

-- 不 fork curl，直接读 wrapper 写的状态文件 + UCI enabled
function action_status()
	local sys = require "luci.sys"
	local fs = require "nixio.fs"
	local uci = require("luci.model.uci").cursor()

	local enabled = uci:get("zjkju-auth", "main", "enabled") or "0"

	local running = false
	local pid = sys.exec("pidof zjkju-auth-wrapper.sh 2>/dev/null")
	if not pid or pid:gsub("%s+", "") == "" then
		pid = sys.exec("pidof zjkju-auth-wrapper 2>/dev/null")
	end
	if pid and pid:gsub("%s+", "") ~= "" then
		running = true
	end

	local status = ""
	if fs.access(STATUS_FILE) then
		status = (fs.readfile(STATUS_FILE) or ""):gsub("%s+", "")
	end

	luci.http.prepare_content("application/json; charset=utf-8")
	luci.http.write_json({
		enabled = enabled,
		running = running,
		online = (status == "online"),
		status = status,
		ts = os.time()
	})
end
