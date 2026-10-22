module("luci.controller.zjkju-auth", package.seeall)

local STATE_DIR   = "/var/log/zjkju-auth"
local LOG_FILE    = STATE_DIR .. "/auth.log"
local STATUS_FILE = STATE_DIR .. "/status"

local FALLBACK_VERSION = "1.0.4"

-- ==========================================
-- 核心：内置代理池
-- ==========================================
local GITHUB_PROXIES = {
	"https://gh-proxy.com/",
	"https://ghfast.top/",
	"https://ghproxy.net/",
	"https://github.moeyy.xyz/",
	"https://gh-proxy.net/",
	"" -- 留空代表直连 GitHub，作为最后的兜底
}

local REPO_API_PATH = "https://api.github.com/repos/woniuchidaodan/zjkju-auth/releases/latest"

-- （省略 index, action_get_log, action_restart, action_clear_log, action_status 等无改动代码）

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

-- ==========================================
-- 核心改进：自动遍历代理池拉取 API
-- ==========================================
local function fetch_latest_release()
	local sys = require "luci.sys"
	local jsonc = require "luci.jsonc"
	local ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

	for _, proxy in ipairs(GITHUB_PROXIES) do
		local full_url = proxy .. REPO_API_PATH
		-- 每个代理最多等 6 秒，避免用户点一下等太久
		local cmd = string.format("curl -sS --fail --max-time 6 -H 'User-Agent: %s' '%s'", ua, full_url)
		local res = sys.exec(cmd)
		
		if res and res ~= "" then
			local ok, parsed = pcall(jsonc.parse, res)
			-- 只要成功解析出 tag_name，就说明这个代理可用
			if ok and type(parsed) == "table" and parsed.tag_name then
				return parsed
			end
		end
	end

	return nil
end

-- （省略 pick_asset 代码）

function action_check_update()
	local http = require "luci.http"

	local current = get_installed_version()
	local result = { current_version = current, has_update = false }

	local rel = fetch_latest_release()
	if not rel then
		result.error = "所有加速节点均请求失败，请检查路由器外网是否通畅"
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

	-- 校验原始地址合法性
	if not url:match("^https://[^/]*github%.com/") and
	   not url:match("^https://[^/]*githubusercontent%.com/") then
		http.write_json({ success = false, error = "安装包原始地址不合法" })
		return
	end

	-- ==========================================
	-- 下载环节：同样遍历代理池
	-- ==========================================
	local target = "/tmp/zjkju-auth-update." .. ext
	local download_success = false

	for _, proxy in ipairs(GITHUB_PROXIES) do
		local download_url = proxy .. url
		-- 下载耗时较长，给 60 秒超时时间
		local dl_cmd = string.format("curl -sS --fail -L --max-time 60 -o %s %s",
			util.shellquote(target), util.shellquote(download_url))
		
		if sys.call(dl_cmd) == 0 then
			local st = fs.stat(target)
			-- 文件大小校验大于 2KB 视为下载成功
			if st and (st.size or 0) > 2048 then
				download_success = true
				break -- 下载成功，跳出代理循环
			end
		end
		fs.remove(target) -- 失败则删掉残缺文件，准备尝试下一个代理
	end

	if not download_success then
		http.write_json({ success = false, error = "下载失败，所有代理均超时，请前往 Releases 手动下载" })
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
