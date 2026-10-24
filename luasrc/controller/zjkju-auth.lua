module("luci.controller.zjkju-auth", package.seeall)

local STATE_DIR   = "/var/log/zjkju-auth"
local STATUS_FILE = STATE_DIR .. "/status"

local FALLBACK_VERSION = "1.0.4-r5"

local GITHUB_PROXIES = {
	"", -- 优先直连
	"https://gh-proxy.com/",
	"https://ghfast.top/",
	"https://github.moeyy.xyz/",
	"https://ghproxy.net/"
}
local REPO_API_PATH = "https://api.github.com/repos/woniuchidaodan/zjkju-auth/releases/latest"

local NODE_TIMEOUT_DIRECT = 8
local NODE_TIMEOUT_PROXY  = 6
local CONSENSUS_BUDGET    = 20

local ASSET_URL_RE =
	"^https://github%.com/woniuchidaodan/zjkju%-auth/releases/download/[%w%._%-/~+]+$"

function index()
	local fs = require "nixio.fs"
	if not fs.access("/etc/config/zjkju-auth") then return end

	entry({"admin", "services", "zjkju-auth"}, cbi("zjkju-auth/main"), _("ZJKJU 校园网认证"), 60).dependent = true
	entry({"admin", "services", "zjkju-auth", "log"}, call("action_get_log")).leaf = true
	entry({"admin", "services", "zjkju-auth", "restart"}, call("action_restart")).leaf = true
	entry({"admin", "services", "zjkju-auth", "clearlog"}, call("action_clear_log")).leaf = true
	entry({"admin", "services", "zjkju-auth", "status"}, call("action_status")).leaf = true
	entry({"admin", "services", "zjkju-auth", "check_update"}, call("action_check_update")).leaf = true
	entry({"admin", "services", "zjkju-auth", "do_update"}, call("action_do_update")).leaf = true
end

-- 纯读模式：只读取 syslog，不再写文件
function action_get_log()
	local http = require "luci.http"
	local sys = require "luci.sys"

	http.prepare_content("text/plain; charset=utf-8")

	local logs = sys.exec("logread -e zjkju-auth 2>/dev/null")
	if not logs or logs == "" then
		if sys.call("pidof logd >/dev/null 2>&1") ~= 0 then
			http.write("（系统 logd 未运行，日志无法采集。请检查 /etc/config/system 的 log_size）")
		else
			http.write("（暂无日志：服务可能未启动过）")
		end
		return
	end

	local sep = "==================== 日志已清空 ===================="
	local _, e = logs:find(".*" .. sep)
	if e then
		logs = logs:sub(e + 1)
	end

	local clean_lines = {}
	local months = {
		Jan="01",Feb="02",Mar="03",Apr="04",May="05",Jun="06",
		Jul="07",Aug="08",Sep="09",Oct="10",Nov="11",Dec="12"
	}

	for line in (logs .. "\n"):gmatch("(.-)\n") do
		if line ~= "" then
			local msg = line:match("zjkju%-auth:%s*(.*)") or line
			local m_str, d_str, t_str, y_str = line:match("(%a+)%s+(%d+)%s+([%d:]+)%s+(%d+)")
			local clean_line = msg
			if m_str and months[m_str] and y_str then
				local mm = months[m_str]
				local dd = string.format("%02d", tonumber(d_str))
				clean_line = y_str .. "-" .. mm .. "-" .. dd .. " " .. t_str .. " " .. msg
			else
				clean_line = line
			end
			table.insert(clean_lines, clean_line)
		end
	end

	local start = math.max(1, #clean_lines - 100 + 1)
	local buf = {}
	for i = start, #clean_lines do buf[#buf + 1] = clean_lines[i] end

	http.write(table.concat(buf, "\n"))
end

function action_clear_log()
	local http = require "luci.http"
	local sys = require "luci.sys"
	sys.call("logger -t zjkju-auth '==================== 日志已清空 ===================='")
	http.prepare_content("application/json")
	http.write('{"ok":true}')
end

function action_restart()
	local http = require "luci.http"
	local sys = require "luci.sys"
	sys.call("/etc/init.d/zjkju-auth restart >/dev/null 2>&1")
	http.prepare_content("text/plain; charset=utf-8")
	http.write("服务已重启")
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
	if pid and pid:gsub("%s+", "") ~= "" then running = true end
	local status = ""
	if fs.access(STATUS_FILE) then
		status = (fs.readfile(STATUS_FILE) or ""):gsub("%s+", "")
	end
	http.prepare_content("application/json; charset=utf-8")
	http.write_json({
		enabled = enabled, running = running, online = (status == "online"), status = status, ts = os.time()
	})
end

local function get_installed_version()
	local sys = require "luci.sys"
	local v = sys.exec("opkg status luci-app-zjkju-auth 2>/dev/null | grep '^Version:' | awk '{print $2}'")
	if not v or v == "" then
		v = sys.exec("apk info -v luci-app-zjkju-auth 2>/dev/null | head -n1 | cut -d'-' -f2-")
	end
	v = (v or ""):gsub("%s+", "")
	local clean_v = v:match("([0-9%.]+%-r[0-9]+%a*)") or v:match("([0-9%.]+)") or ""
	return (clean_v ~= "" and clean_v) or FALLBACK_VERSION
end

local function compare_version(v1, v2)
	v1 = tostring(v1 or ""):gsub("%-r", "."):gsub("%-", ".")
	v2 = tostring(v2 or ""):gsub("%-r", "."):gsub("%-", ".")
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

local function fetch_latest_release()
	local sys = require "luci.sys"
	local jsonc = require "luci.jsonc"
	local ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
	for _, proxy in ipairs(GITHUB_PROXIES) do
		local full_url = proxy .. REPO_API_PATH
		local max_time = (proxy == "") and NODE_TIMEOUT_DIRECT or NODE_TIMEOUT_PROXY
		local cmd = string.format("curl -sS --fail --max-time %d -H 'User-Agent: %s' '%s'", max_time, ua, full_url)
		local res = sys.exec(cmd)
		if res and res ~= "" then
			local ok, parsed = pcall(jsonc.parse, res)
			if ok and type(parsed) == "table" and parsed.tag_name then
				return parsed
			end
		end
	end
	return nil
end

local function get_system_archs()
	local sys = require "luci.sys"
	local archs = {}
	local raw = ""
	if sys.call("command -v opkg >/dev/null 2>&1") == 0 then
		raw = sys.exec("opkg print-architecture 2>/dev/null | awk 'NR>1 {print $2}'")
	else
		raw = sys.exec("apk info --print-arch 2>/dev/null")
	end
	if raw then
		for arch in raw:gmatch("%S+") do archs[arch] = true end
	end
	return archs
end

local function pick_asset(rel, ext, sys_archs)
	if type(rel.assets) ~= "table" then return nil end
	sys_archs = sys_archs or get_system_archs()

	for _, a in ipairs(rel.assets) do
		if type(a) == "table" and a.name and a.browser_download_url and a.name:match("%." .. ext .. "$") then
			local pkg_arch = a.name:match("_([%w%-_]+)%." .. ext .. "$") or a.name:match("%-([%w%-_]+)%." .. ext .. "$")
			if pkg_arch and sys_archs[pkg_arch] then return a end
		end
	end
	for _, a in ipairs(rel.assets) do
		if type(a) == "table" and a.name and a.browser_download_url and a.name:match("%." .. ext .. "$") then
			if a.name:match("_all%." .. ext .. "$") or a.name:match("%-all%." .. ext .. "$") then return a end
		end
	end
	for _, a in ipairs(rel.assets) do
		if type(a) == "table" and a.name and a.browser_download_url and a.name:match("%." .. ext .. "$") then return a end
	end
	return nil
end

local function fetch_consensus_digest(ext)
	local sys = require "luci.sys"
	local jsonc = require "luci.jsonc"
	local ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

	local sys_archs = get_system_archs()
	local counted, urls, tags = {}, {}, {}
	local responses = 0
	local started = os.time()

	for _, proxy in ipairs(GITHUB_PROXIES) do
		if os.time() - started >= CONSENSUS_BUDGET then break end

		local timeout = (proxy == "") and NODE_TIMEOUT_DIRECT or NODE_TIMEOUT_PROXY
		local full_url = proxy .. REPO_API_PATH
		local cmd = string.format("curl -sS --fail --max-time %d -H 'User-Agent: %s' '%s'",
			timeout, ua, full_url)
		local res = sys.exec(cmd)

		if res and res ~= "" then
			local ok, parsed = pcall(jsonc.parse, res)
			if ok and type(parsed) == "table" and parsed.tag_name then
				local asset = pick_asset(parsed, ext, sys_archs)
				local d = asset and asset.digest and tostring(asset.digest):gsub("^sha256:", "")
				local u = asset and asset.browser_download_url

				if d and d:match("^%x+$") and #d == 64 and u and u:match(ASSET_URL_RE) then
					responses = responses + 1
					counted[d] = (counted[d] or 0) + 1
					urls[d] = u
					tags[d] = tostring(parsed.tag_name)
				end
			end
		end
	end

	local best, best_n = nil, 0
	for d, n in pairs(counted) do
		if n > best_n then best, best_n = d, n end
	end

	if not best then
		return nil, nil, "所有节点都没有返回可用的校验值（或安装包地址不合规）。请手动下载。"
	end
	if best_n < 2 then
		return nil, nil, "只有 " .. best_n .. " 个节点返回一致结果，无法交叉验证。为防止投毒已拒绝自动更新，请稍后重试或手动下载。"
	end
	if best_n < responses then
		return nil, nil, "多个节点返回的校验值不一致（可能是加速节点缓存不同步，也可能被篡改），已拒绝自动更新。请稍后重试。"
	end

	return best, urls[best], nil, tags[best]
end

function action_check_update()
	local http = require "luci.http"
	local current = get_installed_version()
	local result = { current_version = current, has_update = false }
	local rel = fetch_latest_release()
	if not rel then
		result.error = "所有加速节点请求失败，请检查外网是否通畅"
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

function action_do_update()
	local http = require "luci.http"
	local sys = require "luci.sys"
	local fs = require "nixio.fs"
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

	local want_hash, url, err = fetch_consensus_digest(ext)
	if not want_hash then
		http.write_json({ success = false, error = err })
		return
	end

	if not url:match(ASSET_URL_RE) then
		http.write_json({ success = false, error = "安装包地址不合法，已阻断非官方仓库源" })
		return
	end

	local bg_script = "/tmp/zjkju_do_update.sh"
	local script_content = string.format([[
#!/bin/sh
URL="%s"
EXT="%s"
WANT_HASH="%s"
TARGET="/tmp/zjkju_auth_update.$EXT"
PROXIES="/ gh-proxy.com/ ghfast.top/ github.moeyy.xyz/ ghproxy.net/"

for P in $PROXIES; do
    if [ "$P" = "/" ]; then
        FULL_URL="$URL"
    else
        FULL_URL="https://$P$URL"
    fi

    curl -sS --fail -L --connect-timeout 4 --max-time 60 -o "$TARGET" "$FULL_URL"

    if [ -s "$TARGET" ]; then
        GOT_HASH=$(sha256sum "$TARGET" | awk '{print $1}')
        if [ "$GOT_HASH" = "$WANT_HASH" ]; then
            if command -v opkg >/dev/null 2>&1; then
                opkg install "$TARGET" >/dev/null 2>&1
            else
                apk add --allow-untrusted "$TARGET" >/dev/null 2>&1
            fi
            rm -f "$TARGET" "$0"
            /etc/init.d/zjkju-auth restart >/dev/null 2>&1
            exit 0
        fi
    fi
    rm -f "$TARGET"
done
rm -f "$TARGET" "$0"
exit 1
]], url, ext, want_hash)

	fs.writefile(bg_script, script_content)
	sys.call("chmod +x " .. bg_script)
	sys.call("(sleep 1; " .. bg_script .. ") >/dev/null 2>&1 &")
	http.write_json({ success = true })
end
