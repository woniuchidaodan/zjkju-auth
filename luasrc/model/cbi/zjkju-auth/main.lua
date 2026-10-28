local translate = require("luci.i18n").translate
local uci       = require("luci.model.uci").cursor()
local sys       = require "luci.sys"

local m, s, o

local PKG_VERSION = "1.0.4-r10"
do
	local v = sys.exec("opkg status luci-app-zjkju-auth 2>/dev/null | grep '^Version:' | awk '{print $2}'")
	if not v or v == "" then
		v = sys.exec("apk info -v luci-app-zjkju-auth 2>/dev/null | head -n1 | cut -d'-' -f2-")
	end
	v = (v or ""):gsub("%s+", "")
	local clean_v = v:match("([0-9%.]+%-r[0-9]+%a*)")
		or v:match("([0-9%.]+%-[0-9]+)")
		or v:match("([0-9%.]+)") or ""
	-- opkg 的 Version 形如 "1.0.4-10"，统一规范成 "1.0.4-r10" 才能和 tag 比较
	clean_v = clean_v:gsub("%-(%d+)$", "-r%1")
	if clean_v ~= "" then PKG_VERSION = clean_v end
end

m = Map("zjkju-auth",
	translate("ZJKJU 校园网认证") .. " <span style='font-size:12px; color:#888; font-weight:normal; margin-left:8px;'>Version: " .. PKG_VERSION .. "</span>",
	translate("在路由器上自动完成校园网 ePortal 认证。填写学号和密码后，勾选“启用”并保存。"))

s = m:section(NamedSection, "main", "zjkju-auth", translate("认证设置"))
s.anonymous = true
s.addremove = false

s:tab("basic", translate("认证设置"))
s:tab("other", translate("其他设置"))

o = s:taboption("basic", Flag, "enabled", translate("启用"),
	translate("勾选并保存后，服务会立即启动；取消勾选保存会停止服务"))
o.default = 0
o.rmempty = false

o = s:taboption("basic", Value, "username", translate("用户名"),
	translate("用户名，一般为学号，如果是新生且无学号，用户名一般为ZK开头的临时账号"))
o.datatype = "string"
-- rmempty = true：清空保存时直接从配置里删除该项，避免空值写不进去导致旧值残留
o.rmempty = true

o = s:taboption("basic", Value, "password", translate("密码"),
	translate("密码，初始为身份证后六位"))
o.password = true
o.datatype = "string"
-- 同上：清空即删除配置项
o.rmempty = true

o = s:taboption("basic", ListValue, "service", translate("服务类型"),
	translate("默认使用“电信校园网”，一般无需修改"))
o:value("%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91", translate("电信校园网"))
o.default = "%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91"
o.rmempty = false

local current = uci:get("zjkju-auth", "main", "service") or ""
if current ~= "" and current ~= "%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91" then
	o:value(current, current .. translate("（当前已保存）"))
end

o = s:taboption("basic", Value, "manual_url", translate("手动认证地址"),
	translate("通常留空。只有自动抓取和缓存都失败时才会用到这个地址"))
o.datatype = "string"
o.rmempty = true

o = s:taboption("other", Flag, "beta_channel", translate("接收测试版"),
	translate("开启后会收到标为 pre-release 的版本，仅建议测试用户开启"))
o.default = 0
o.rmempty = false

-- 纯文本 DummyValue（不用 rawhtml），避免任何 HTML 混进 CBI 控件
o = s:taboption("other", DummyValue, "_log_location", translate("日志文件"))
o.default = "/var/log/zjkju-auth/auth.log"
o.description = translate("日志同时写入系统日志和本地文件。同目录下还有 status、last-url 等运行时文件。")

-- 版本更新：这里只放"版本号 + 按钮"的轻量 HTML（无 style 块、无 script、无弹窗结构），
-- 弹窗、样式和脚本都放在 update.htm 里，避免它们混进 CBI 控件影响变更检测。
o = s:taboption("other", DummyValue, "_version_check", translate("版本更新"))
o.rawhtml = true
o.default = [=[<div style="margin-top:4px;">]=] .. [=[
	<div style="margin-bottom:6px;">当前版本：<code>]=] .. PKG_VERSION .. [=[</code></div>
	<span style="display:inline-block;">
	<button type="button" class="cbi-button cbi-button-action" style="position:relative;outline:none;display:inline-block!important;width:auto!important;min-width:0!important;max-width:100%!important;height:auto!important;min-height:0!important;line-height:1.5!important;padding:6px 16px!important;margin:0!important;font-size:13px!important;box-sizing:border-box!important;" onclick="zjkjuCheckUpdate()">
		检查更新
		<span id="zjkju-red-dot" style="display:none;position:absolute;top:-4px;right:-4px;width:10px;height:10px;background:#e74c3c;border-radius:50%;box-shadow:0 0 0 2px #fff;"></span>
	</button>
	</span>
	<span id="zjkju-update-msg" style="margin-left:10px;"></span>
</div>]=]

-- 日志面板：独立模板，位于标签页下方
local sec = m:section(SimpleSection)
sec.template = "zjkju-auth/log"

-- 版本更新：弹窗 + 样式 + 脚本独立模板（在标签页下方，不进 CBI 控件）
local sec2 = m:section(SimpleSection)
sec2.template = "zjkju-auth/update"

-- 保存后根据 enabled 决定启动还是停止。
-- 注意：on_after_commit 触发时配置文件可能尚未落盘，
-- 必须先 commit，否则 /etc/init.d 的 start_service 读到的还是旧值（表现为"要点两次"）。
-- ============================================================
-- 【硬性约束 · 不要改动】
--   ① 读秒：下面的 sleep 2 是前端「正在应用更改」遮罩可见的前提。
--      不能删除、不能小于 2 秒，否则遮罩一闪而过或完全不出现。
--   ② 一次点击生效：必须先 self.uci:commit()，再调用 start。
--      否则 start_service 读到的还是旧配置，表现为「要点两次保存才生效」。
--   ③ 徽章：进程状态由 controller 用 ubus 判断，不要改回 pidof。
-- ============================================================
function m.on_after_commit(self)
	self.uci:commit("zjkju-auth")
	sys.call("uci commit zjkju-auth")

	-- 决策用内存值（一定包含本次修改）；磁盘值只用于日志对照
	local enabled      = self.uci:get("zjkju-auth", "main", "enabled")
	local enabled_disk = sys.exec("uci -q get zjkju-auth.main.enabled 2>/dev/null"):gsub("%s+", "")
	sys.call("logger -t zjkju-auth '保存后判断: mem=[" .. tostring(enabled) .. "] disk=[" .. enabled_disk .. "]'")

	-- 与 wrapper 的 config_get_bool 保持一致的判真集合
	if enabled == "1" or enabled == "on" or enabled == "true"
	   or enabled == "yes" or enabled == "enabled" then
		sys.call("/etc/init.d/zjkju-auth enable >/dev/null 2>&1")
		sys.call("/etc/init.d/zjkju-auth stop >/dev/null 2>&1")

		-- 等旧进程退出（wrapper 收到 TERM 后 1 秒内退出），最多等 3 秒
		sys.call("i=0; while [ $i -lt 3 ] && { pidof zjkju-auth-wrapper.sh >/dev/null 2>&1 || pidof zjkju-auth-wrapper >/dev/null 2>&1; }; do i=$((i+1)); sleep 1; done")
		sys.call("pidof zjkju-auth-wrapper.sh >/dev/null 2>&1 || pidof zjkju-auth-wrapper >/dev/null 2>&1 && killall -9 zjkju-auth-wrapper.sh zjkju-auth-wrapper 2>/dev/null")

		local rc = sys.call("/etc/init.d/zjkju-auth start >/dev/null 2>&1")

		-- 停 2 秒：① 让前端"正在应用更改"的遮罩可见 ② 等 procd 真正 fork 出进程再统计
		sys.call("sleep 2")

		local cnt = sys.exec("ps 2>/dev/null | grep -c '[z]jkju-auth-wrapper'")
		sys.call("logger -t zjkju-auth '启动完成 rc=" .. rc .. " 进程数=" .. (cnt:gsub("%s+", "")) .. "'")
	else
		-- 强制停止：断自启 → 停实例 → 让 procd 忘记 → 强杀 → 清残留
		sys.call("/etc/init.d/zjkju-auth disable >/dev/null 2>&1")
		sys.call("/etc/init.d/zjkju-auth stop >/dev/null 2>&1")
		sys.call("ubus call service delete '{\"name\":\"zjkju-auth\"}' >/dev/null 2>&1")
		sys.call("for p in $(pidof zjkju-auth-wrapper.sh) $(pidof zjkju-auth-wrapper); do kill -9 $p; done >/dev/null 2>&1")
		sys.call("killall -9 zjkju-auth-wrapper.sh zjkju-auth-wrapper 2>/dev/null")
		sys.call("rm -f /var/log/zjkju-auth/status /var/log/zjkju-auth/last-url /var/log/zjkju-auth/online-printed 2>/dev/null")
		sys.call("rm -f /tmp/zjkju_do_update.sh /tmp/zjkju_update_status 2>/dev/null")

		-- 同样停 2 秒，让"停止服务"的遮罩可见
		sys.call("sleep 2")
	end
end

return m
