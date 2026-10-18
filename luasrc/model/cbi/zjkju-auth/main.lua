local translate = require("luci.i18n").translate
local uci       = require("luci.model.uci").cursor()

local m, s, o

m = Map("zjkju-auth", translate("ZJKJU 校园网认证"),
	translate("在路由器上自动完成校园网 ePortal 认证。填写学号和密码后，勾选“启用”并保存。"))

s = m:section(NamedSection, "main", "zjkju-auth", translate("认证设置"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用"),
	translate("勾选并保存后，服务会立即启动；取消勾选保存会停止服务"))
o.default = 0
o.rmempty = false

o = s:option(Value, "username", translate("用户名"),
	translate("校园网账号，一般为学号，如果是新生且无学号，用户名一般为ZK开头的临时账号"))
o.datatype = "string"
o.rmempty = false

o = s:option(Value, "password", translate("密码"),
	translate("校园网密码，初始为身份证后六位"))
o.password = true
o.datatype = "string"
o.rmempty = false

o = s:option(ListValue, "service", translate("服务类型"),
	translate("默认使用“电信校园网”，一般无需修改"))
o:value("%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91", translate("电信校园网"))
o.default = "%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91"
o.rmempty = false

local current = uci:get("zjkju-auth", "main", "service") or ""
if current ~= "" and current ~= "%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91" then
	o:value(current, current .. translate("（当前已保存）"))
end

o = s:option(Value, "manual_url", translate("手动认证地址"),
	translate("通常留空。只有自动抓取和缓存都失败时才会用到这个地址"))
o.datatype = "string"
o.rmempty = true

o = s:option(DummyValue, "_log_location", translate("日志文件"))
o.rawhtml = true
o.default = "<code>/var/log/zjkju-auth/auth.log</code>"
o.description = translate("默认 /var/log/zjkju-auth/auth.log。同目录下还有 status、last-url 等运行时文件")

local sec = m:section(SimpleSection)
sec.template = "zjkju-auth/log"

-- 保存后根据 enabled 决定启动还是停止。
-- 注意：on_after_commit 触发时配置已经 commit 完成（cbi.lua 里 uci:save() 在前），
-- 所以这里同步重启即可，不需要延时。
function m.on_after_commit(self)
	local uci2 = require("luci.model.uci").cursor()
	local enabled = uci2:get("zjkju-auth", "main", "enabled")

	-- 与 wrapper 的 config_get_bool 保持一致的判真集合
	if enabled == "1" or enabled == "on" or enabled == "true"
	   or enabled == "yes" or enabled == "enabled" then
		luci.sys.call("/etc/init.d/zjkju-auth enable >/dev/null 2>&1")
		luci.sys.call("/etc/init.d/zjkju-auth restart >/dev/null 2>&1")
	else
		luci.sys.call("/etc/init.d/zjkju-auth stop >/dev/null 2>&1")
		luci.sys.call("/etc/init.d/zjkju-auth disable >/dev/null 2>&1")
	end
end

return m
