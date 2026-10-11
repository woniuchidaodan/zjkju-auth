local translate = require("luci.i18n").translate
local uci       = require("luci.model.uci").cursor()

local m, s, o

m = Map("zjkju-auth", translate("ZJKJU 校园网认证"),
	translate("湛江科技学院锐捷 ePortal 自动认证。填写学号和密码后保存，服务会自动在后台运行。"))

s = m:section(NamedSection, "main", "zjkju-auth", translate("基本设置"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用"))
o.default = 1
o.rmempty = false

o = s:option(Value, "username", translate("学号"))
o.datatype = "string"
o.rmempty = false

o = s:option(Value, "password", translate("密码"))
o.password = true
o.datatype = "string"
o.rmempty = false

-- 服务类型：前端显示"电信校园网"，底层存 %E7%94%B5...
o = s:option(ListValue, "service", translate("服务类型"))
o:value("%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91", translate("电信校园网"))
o.default = "%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91"
o.rmempty = false
o.description = translate("电信校园网请保持默认值")

-- 兜底：UCI 里有其他值时也列出
local current = uci:get("zjkju-auth", "main", "service") or ""
if current ~= "" and current ~= "%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91" then
	o:value(current, current .. translate("（当前已保存）"))
end

o = s:option(TextValue, "manual_url", translate("手动认证 URL（可选）"),
	translate("自动抓取失败时的兜底。留空则自动抓取。可以从浏览器地址栏复制完整认证页 URL 粘贴到这里。"))
o.rows = 3
o.rmempty = true
o.optional = true

local sec = m:section(SimpleSection)
sec.template = "zjkju-auth/log"

return m
