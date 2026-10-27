module("luci.controller.zjkju-auth", package.seeall)

local STATE_DIR   = "/var/log/zjkju-auth"
local LOG_FILE    = STATE_DIR .. "/auth.log"
local STATUS_FILE = STATE_DIR .. "/status"

local FALLBACK_VERSION = "1.0.4-r8"

local GITHUB_PROXIES = {
	"",
	"https://gh-proxy.com/",
	"https://ghfast.top/"
}

local REPO_API_PATH = "https://api.github.com/repos/woniuchidaodan/zjkju-auth/releases?per_page=10"

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
	entry({"admin", "services", "zjkju-auth", "update_status"}, call("action_update_status")).leaf = true
end

function action_update_status()
	local http = require "luci.http"
	local fs = require "nixio.fs"
	local status_file = "/tmp/zjkju_update_status"
	http.prepare_content("text/plain; charset=utf-8")
	if fs.access(status_file) then
		http.write(fs.readfile(status_file) or "0|等待中|0")
	else
		http.write("0|等待中|0")
	end
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

	local lines = {}
	for line in (data .. "\n"):gmatch("(.-)\n") do
		if line ~= "" then lines[#lines + 1] = line end
	end

	local start = math.max(1, #lines - 100 + 1)
	local buf = {}
	for i = start, #lines do buf[#buf + 1] = lines[i] end

	http.write(table.concat(buf, "\n"))
end

function action_clear_log()
	local http = require "luci.http"
	local fs = require "nixio.fs"
	local sys = require "luci.sys"
	
	fs.writefile(LOG_FILE, "")
	sys.call("logger -t zjkju-auth '[系统提示] 用户已手动清空文件日志'")
	
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
	-- 注意：Linux 的 comm 只有 15 字符（zjkju-auth-wrap），
	-- pidof 用完整文件名匹配不上，必须用 ps 找命令行。
	local running = false
	local pline = sys.exec("ps w 2>/dev/null | grep '[z]jkju-auth-wrapper' | head -n1")
	if pline and pline:gsub("%s+", "") ~= "" then running = true end
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
	local clean_v = v:match("([0-9%.]+%-r[0-9]+%a*)")
		or v:match("([0-9%.]+%-[0-9]+)")
		or v:match("([0-9%.]+)") or ""
	-- opkg 的 Version 形如 "1.0.4-8"，统一规范成 "1.0.4-r8" 才能和 tag 比较
	clean_v = clean_v:gsub("%-(%d+)$", "-r%1")
	return (clean_v ~= "" and clean_v) or FALLBACK_VERSION
end

local function compare_version(v1, v2)
	if v1 == v2 then return 0 end
	local n1 = tostring(v1 or ""):gsub("%-r", "."):gsub("%-", "."):gsub("%a", "")
	local n2 = tostring(v2 or ""):gsub("%-r", "."):gsub("%-", "."):gsub("%a", "")
	local t1, t2 = {}, {}
	for n in string.gmatch(n1, "%d+") do t1[#t1 + 1] = tonumber(n) end
	for n in string.gmatch(n2, "%d+") do t2[#t2 + 1] = tonumber(n) end
	local mx = math.max(#t1, #t2)
	for i = 1, mx do
		local a, b = t1[i] or 0, t2[i] or 0
		if a > b then return 1 end
		if a < b then return -1 end
	end
	return 0
end

local function beta_enabled()
	local ok, uci = pcall(require, "luci.model.uci")
	if not ok then return false end
	return uci.cursor():get("zjkju-auth", "main", "beta_channel") == "1"
end

local function pick_newest(parsed)
	local allow_beta = beta_enabled()
	if type(parsed) ~= "table" then return nil end
	if parsed.tag_name then
		if not allow_beta and parsed.prerelease then return nil end
		return parsed
	end

	local best = nil
	for _, r in ipairs(parsed) do
		if type(r) == "table" and r.tag_name and not r.draft then
			if allow_beta or not r.prerelease then
				if not best then
					best = r
				else
					local c = compare_version(r.tag_name, best.tag_name)
					if c > 0 or (c == 0 and best.prerelease and not r.prerelease) then
						best = r
					end
				end
			end
		end
	end
	return best
end

local function fetch_latest_release()
	local sys = require "luci.sys"
	local jsonc = require "luci.jsonc"
	local ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
	local answered = false
	
	for _, proxy in ipairs(GITHUB_PROXIES) do
		local max_time = (proxy == "") and NODE_TIMEOUT_DIRECT or NODE_TIMEOUT_PROXY
		local cmd = string.format("curl -sS --fail --max-time %d -H 'User-Agent: %s' '%s'",
			max_time, ua, proxy .. REPO_API_PATH)
		local res = sys.exec(cmd)
		if res and res ~= "" then
			local ok, parsed = pcall(jsonc.parse, res)
			if ok then
				answered = true
				local rel = pick_newest(parsed)
				if rel then return rel, answered end
			end
		end
	end
	return nil, answered
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

local function fetch_one(proxy, ext, sys_archs)
	local sys = require "luci.sys"
	local jsonc = require "luci.jsonc"
	local ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

	local timeout = (proxy == "") and NODE_TIMEOUT_DIRECT or NODE_TIMEOUT_PROXY
	local cmd = string.format("curl -sS --fail --max-time %d -H 'User-Agent: %s' '%s'",
		timeout, ua, proxy .. REPO_API_PATH)

	local res = sys.exec(cmd)
	if not res or res == "" then return nil end

	local ok, parsed = pcall(jsonc.parse, res)
	if not ok then return nil end

	local rel = pick_newest(parsed)
	if not rel then return nil end

	local asset = pick_asset(rel, ext, sys_archs)
	local d = asset and asset.digest and tostring(asset.digest):gsub("^sha256:", "")
	local u = asset and asset.browser_download_url
	local sz = asset and asset.size

	if not (d and d:match("^%x+$") and #d == 64 and u and u:match(ASSET_URL_RE)) then
		return nil
	end
	return d, u, tostring(rel.tag_name), sz
end

local function fetch_consensus_digest(ext)
	local sys_archs = get_system_archs()
	local started = os.time()

	local d, u, t, sz = fetch_one("", ext, sys_archs)
	if d then
		return d, u, nil, t, sz
	end

	local votes, urls, tags, sizes, responses = {}, {}, {}, {}, 0

	for _, proxy in ipairs(GITHUB_PROXIES) do
		if proxy ~= "" then
			if os.time() - started >= CONSENSUS_BUDGET then break end

			local dd, uu, tt, ss = fetch_one(proxy, ext, sys_archs)
			if dd then
				responses = responses + 1
				votes[dd] = (votes[dd] or 0) + 1
				urls[dd]  = uu
				tags[dd]  = tt
				sizes[dd] = ss
			end
		end
	end

	local best, best_n = nil, 0
	for dd, n in pairs(votes) do
		if n > best_n then best, best_n = dd, n end
	end

	if not best then
		return nil, nil, "直连与所有加速节点均不可用，请检查网络或手动下载。"
	end
	if best_n < 2 then
		return nil, nil, "直连不可用，且只有 1 个加速节点响应，无法交叉验证。请稍后重试或手动下载。"
	end
	if best_n < responses then
		return nil, nil, "多个加速节点返回的校验值不一致（可能缓存不同步），请稍后重试。"
	end

	return best, urls[best], nil, tags[best], sizes[best]
end

function action_check_update()
	local http = require "luci.http"
	local current = get_installed_version()
	local result = { current_version = current, has_update = false }
	local rel, answered = fetch_latest_release()
	if not rel then
		if answered and not beta_enabled() then
			result.error = "未找到正式版（当前仅存在测试版）。如需接收测试版，请在“其他设置”中开启。"
		else
			result.error = "所有节点请求失败，请检查外网是否通畅"
		end
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

	local want_hash, url, err, tag, size = fetch_consensus_digest(ext)
	if not want_hash then
		http.write_json({ success = false, error = err })
		return
	end

	local latest = tostring(tag or ""):gsub("^v", "")
	if latest == "" or compare_version(latest, get_installed_version()) <= 0 then
		http.write_json({ success = false, error = "当前已是最新版本，无需更新" })
		return
	end

	if not url:match(ASSET_URL_RE) then
		http.write_json({ success = false, error = "安装包地址不合法，已阻断非官方仓库源" })
		return
	end

	local total_size = tonumber(size) or 0
	fs.writefile("/tmp/zjkju_update_status", "0|准备中|0")
	
	local bg_script = "/tmp/zjkju_do_update.sh"
	local fmt_ok, script_content = pcall(string.format, [[
#!/bin/sh
URL="%s"
EXT="%s"
WANT_HASH="%s"
TOTAL_HINT="%s"
TARGET="/tmp/zjkju_auth_update.$EXT"
STATUS_FILE="/tmp/zjkju_update_status"
PROXIES="/ gh-proxy.com/ ghfast.top/"

# 原子写入：先写临时文件再 rename，避免前端读到只写了一半的内容
# 注意：这段会被 Lua 的 string.format 处理，注释里不能出现百分号，
#       所以这里用 echo -n 而不是 printf
set_status() {
    echo -n "$1" > "$STATUS_FILE.tmp" 2>/dev/null && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE" 2>/dev/null
}

set_status "1|下载中|0"

for P in $PROXIES; do
    if [ "$P" = "/" ]; then
        FULL_URL="$URL"
    else
        FULL_URL="https://$P$URL"
    fi

    TOTAL="$TOTAL_HINT"
    [ -z "$TOTAL" ] && TOTAL=0
    if [ "$TOTAL" -eq 0 ]; then
        TOTAL=$(curl -sIL --max-time 10 "$FULL_URL" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
        [ -z "$TOTAL" ] && TOTAL=0
    fi

    rm -f "$TARGET"
    
    curl -sS --fail -L --connect-timeout 4 --max-time 60 -o "$TARGET" "$FULL_URL" 2>/dev/null &
    CPID=$!

    n=0
    while kill -0 "$CPID" 2>/dev/null; do
        n=$((n + 1))
        [ "$n" -gt 90 ] && break
        CUR=$(wc -c < "$TARGET" 2>/dev/null || echo 0)
        if [ "$TOTAL" -gt 0 ] 2>/dev/null; then
            set_status "1|下载中|$((CUR * 100 / TOTAL))"
        else
            set_status "1|下载中"
        fi
        sleep 1
    done
    wait "$CPID" 2>/dev/null
    CURL_RC=$?

    if [ "$CURL_RC" = "0" ] && [ -s "$TARGET" ]; then
        # 先亮出满进度并停留 1 秒（busybox 的 sleep 不支持小数），
        # 保证 500ms 轮询的前端至少能读到一次进度
        set_status "1|下载中|100"
        sleep 1
        set_status "2|校验中|100"
        GOT_HASH=$(sha256sum "$TARGET" | awk '{print $1}')
        if [ "$GOT_HASH" = "$WANT_HASH" ]; then
            set_status "3|安装中|100"
            if command -v opkg >/dev/null 2>&1; then
                opkg install "$TARGET" >/dev/null 2>&1
            else
                apk add --allow-untrusted "$TARGET" >/dev/null 2>&1
            fi
            rm -f "$TARGET" "$0"
            /etc/init.d/zjkju-auth restart >/dev/null 2>&1
            set_status "4|安装完成|100"
            exit 0
        fi
    fi
    rm -f "$TARGET"
done
set_status "-1|下载失败或校验不通过，请重试或手动下载|0"
rm -f "$0"
exit 1
]], url, ext, want_hash, total_size)
	if not fmt_ok then
		http.write_json({ success = false, error = "生成更新脚本出错：" .. tostring(script_content) })
		return
	end

	fs.writefile(bg_script, script_content)
	sys.call("chmod +x " .. bg_script)
	sys.call("(sleep 1; " .. bg_script .. ") >/dev/null 2>&1 &")
	http.write_json({ success = true })
end
