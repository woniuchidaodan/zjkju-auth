module("luci.controller.zjkju-auth", package.seeall)

local STATE_DIR   = "/var/log/zjkju-auth"
local LOG_FILE    = STATE_DIR .. "/auth.log"
local STATUS_FILE = STATE_DIR .. "/status"

-- 版本以 Makefile 为准；这里只是 opkg 读不到时的兜底
local FALLBACK_VERSION = "1.0.4"

-- GitHub 仓库（自动更新只允许从这个仓库取包）
local REPO_API = "https://api.github.com/repos/woniuchidaodan/zjkju-auth/releases/latest"

function index()
	local fs = require "nixio.fs"

	if not fs.access("/etc/config/zjkju-auth") then
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

	entry({"admin", "services", "zjkju-auth", "check_update"},
		call("action_check_update")).leaf = true

	entry({"admin", "services", "zjkju-auth", "do_update"},
		call("action_do_update")).leaf = true
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
	local http = require "luci.http"
	local sys = require "luci.sys"

	sys.call("/etc/init.d/zjkju-auth restart >/dev/null 2>&1")
	http.prepare_content("text/plain; charset=utf-8")
	http.write("服务已重启")
end

function action_clear_log()
	local http = require "luci.http"
	local fs = require "nixio.fs"

	fs.writefile(LOG_FILE, "")

	http.prepare_content("application/json")
	http.write('{"ok":true}')
end

function action_status()
	local http = require "luci.http"
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

	http.prepare_content("application/json; charset=utf-8")
	http.write_json({
		enabled = enabled,
		running = running,
		online = (status == "online"),
		status = status,
		ts = os.time()
	})
end

-- 从 opkg 读已安装版本，精准切掉后缀
local function get_installed_version()
	local sys = require "luci.sys"
	local v = sys.exec("opkg status luci-app-zjkju-auth 2>/dev/null | grep '^Version:' | awk '{print $2}' | cut -d'-' -f1")
	if not v or v == "" then
		v = sys.exec("apk info -v luci-app-zjkju-auth 2>/dev/null | head -n1 | cut -d'-' -f2")
	end
	v = (v or ""):match("[0-9][0-9%.]*") or ""
	return (v ~= "" and v) or FALLBACK_VERSION
end

local function compare_version(v1, v2)
	v1 = (v1 or ""):match("[0-9][0-9%.]*") or ""
	v2 = (v2 or ""):match("[0-9][0-9%.]*") or ""
	local t1, t2 = {}, {}
	for n in string.gmatch(v1, "%d+") do t1[#t1 + 1] = tonumber(n) end
	for n in string.gmatch(v2, "%d+") do t2[#t2 + 1] = tonumber(n) end
	local mx = math.max(#t1, #t2)
	for i = 1, mx do
		local a, b = t1[i] or 0, t2[i] or 0
		if a > b then return 1 end
		if a < b then return -1 end
	end
	return 0
end

-- 拉取最新 release
local function fetch_latest_release()
	local sys = require "luci.sys"
	local jsonc = require "luci.jsonc"

	local res = sys.exec("curl -sS --fail --max-time 10 -H 'User-Agent: OpenWrt' '" .. REPO_API .. "'")
	if not res or res == "" then
		return nil
	end

	local ok, parsed = pcall(jsonc.parse, res)
	if ok and type(parsed) == "table" and parsed.tag_name then
		return parsed
	end
	return nil
end

-- 按扩展名选 asset
local function pick_asset(rel, ext)
	if type(rel.assets) ~= "table" then
		return nil
	end
	for _, a in ipairs(rel.assets) do
		if type(a) == "table" and a.name and a.browser_download_url
		   and a.name:match("%." .. ext .. "$") then
			return a
		end
	end
	return nil
end

function action_check_update()
	local http = require "luci.http"

	local current = get_installed_version()
	local result = { current_version = current, has_update = false }

	local rel = fetch_latest_release()
	if not rel then
		result.error = "请求超时或无法连接 GitHub，请检查路由器网络"
	else
		local latest = tostring(rel.tag_name):gsub("^v", "")
		result.latest_version = latest
		result.body = rel.body or ""
		result.download_url = rel.html_url or ""
		if compare_version(latest, current) > 0 then
			result.has_update = true
		end
	end

	http.prepare_content("application/json; charset=utf-8")
	http.write_json(result)
end

-- 自动更新：服务端推导 URL
function action_do_update()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local fs = require "nixio.fs"
	local util = require "luci.util"

	http.prepare_content("application/json; charset=utf-8")

	if (http.getenv("REQUEST_METHOD") or ""):upper() ~= "POST" then
		http.status(405, "Method Not Allowed")
		http.write_json({ success = false, error = "仅支持 POST" })
		return
	end

	local dispatcher = require "luci.dispatcher"
	if (http.formvalue("token") or "") ~= (dispatcher.context.authtoken or "") then
		http.status(403, "Forbidden")
		http.write_json({ success = false, error = "令牌校验失败" })
		return
	end

	local has_opkg = (sys.call("command -v opkg >/dev/null 2>&1") == 0)
	local has_apk  = (sys.call("command -v apk >/dev/null 2>&1") == 0)
	if not has_opkg and not has_apk then
		http.write_json({ success = false, error = "未找到 opkg 或 apk" })
		return
	end
	local ext = has_opkg and "ipk" or "apk"

	local rel = fetch_latest_release()
	if not rel then
		http.write_json({ success = false, error = "无法获取最新版本信息" })
		return
	end
	local asset = pick_asset(rel, ext)
	if not asset then
		http.write_json({ success = false, error = "Release 里没有 " .. ext .. " 安装包" })
		return
	end
	local url = asset.browser_download_url

	if not url:match("^https://[^/]*github%.com/") and
	   not url:match("^https://[^/]*githubusercontent%.com/") then
		http.write_json({ success = false, error = "安装包地址不合法" })
		return
	end

	local target = "/tmp/zjkju-auth-update." .. ext
	local dl_cmd = string.format("curl -sS --fail -L --max-time 90 -o %s %s",
		util.shellquote(target), util.shellquote(url))
	if sys.call(dl_cmd) ~= 0 then
		fs.remove(target)
		http.write_json({ success = false, error = "下载安装包失败" })
		return
	end

	local st = fs.stat(target)
	if not st or (st.size or 0) < 2048 then
		fs.remove(target)
		http.write_json({ success = false, error = "下载内容异常" })
		return
	end

	local install_cmd
	if has_opkg then
		install_cmd = "opkg install " .. util.shellquote(target) .. " >/dev/null 2>&1"
	else
		install_cmd = "apk add --allow-untrusted " .. util.shellquote(target) .. " >/dev/null 2>&1"
	end
	local irc = sys.call(install_cmd)
	fs.remove(target)

	if irc == 0 then
		http.write_json({ success = true })
	else
		http.write_json({ success = false, error = "安装失败，请检查日志或手动安装" })
	end
end
