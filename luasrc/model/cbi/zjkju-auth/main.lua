local translate = require("luci.i18n").translate
local uci       = require("luci.model.uci").cursor()

local m, s, o

m = Map("zjkju-auth", translate("ZJKJU 校园网认证"),
	translate("在路由器上自动完成校园网 ePortal 认证。修改后请点击“保存并应用”，服务会立即重启。"))

s = m:section(NamedSection, "main", "zjkju-auth", translate("认证设置"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用认证"),
	translate("勾选并保存后，开机自动启动认证服务"))
o.default = 1
o.rmempty = false

o = s:option(Value, "username", translate("学号"),
	translate("校园网账号，一般就是学号"))
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
	translate("留空表示自动探测。只有自动获取失败时才需要填完整认证页地址"))
o.datatype = "string"
o.rmempty = true
o.optional = true

-- 日志文件（只读）
o = s:option(DummyValue, "_log_location", translate("日志文件"))
o.rawhtml = true
o.default = "<code>/var/log/zjkju-auth.log</code>"
o.description = translate("默认 /var/log/zjkju-auth.log（内存盘，重启清空）。想重启后保留可改成 /etc/zjkju-auth.log")

-- 运行日志区
local sec = m:section(SimpleSection)
sec.template = "zjkju-auth/log"

return m
