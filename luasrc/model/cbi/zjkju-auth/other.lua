local translate = require("luci.i18n").translate

local m, s, o

m = Map("zjkju-auth",
	translate("ZJKJU 校园网认证") .. " - " .. translate("其他设置"),
	translate("日志位置、测试版通道和版本更新。"))

s = m:section(NamedSection, "main", "zjkju-auth", translate("其他设置"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_log_location", translate("日志文件"))
o.rawhtml = true
o.default = "<code>/var/log/zjkju-auth/auth.log</code>"
o.description = translate("日志同时写入系统日志和本地文件。同目录下还有 status、last-url 等运行时文件。")

o = s:option(Flag, "beta_channel", translate("接收测试版"),
	translate("开启后会收到标为 pre-release 的版本，仅建议测试用户开启"))
o.default = 0
o.rmempty = false

-- 版本更新区块（按钮 + 弹窗 + 脚本）由独立模板渲染，
-- 避免把 <script> 塞进 CBI 控件里影响表单的变更检测。
local sec = m:section(SimpleSection)
sec.template = "zjkju-auth/update"

return m
