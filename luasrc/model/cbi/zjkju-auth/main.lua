local translate = require("luci.i18n").translate
local uci       = require("luci.model.uci").cursor()
local sys       = require "luci.sys"
local disp      = require "luci.dispatcher"

local m, s, o

-- 版本以 Makefile 为准：从已安装包读，读不到再回落
local PKG_VERSION = "1.0.4"
do
	local v = sys.exec("opkg list-installed luci-app-zjkju-auth 2>/dev/null | awk '{print $3}'")
	v = (v or ""):match("[0-9][0-9%.]*") or ""
	if v ~= "" then PKG_VERSION = v end
end

-- 将版本号拼接到大标题后面
m = Map("zjkju-auth", 
	translate("ZJKJU 校园网认证") .. " <span style='font-size:12px; color:#888; font-weight:normal; margin-left:8px;'>Version: " .. PKG_VERSION .. "</span>",
	translate("在路由器上自动完成校园网 ePortal 认证。填写学号和密码后，勾选“启用”并保存。"))

-- 一个 NamedSection，两个 tab（双页）
s = m:section(NamedSection, "main", "zjkju-auth", translate("认证设置"))
s.anonymous = true
s.addremove = false

s:tab("basic", translate("认证设置"), translate("学号、密码与服务类型"))
s:tab("other", translate("其他设置"), translate("日志文件与版本更新"))

-- ============ Tab 1：认证设置 ============
o = s:taboption("basic", Flag, "enabled", translate("启用"),
	translate("勾选并保存后，服务会立即启动；取消勾选保存会停止服务"))
o.default = 0
o.rmempty = false

o = s:taboption("basic", Value, "username", translate("用户名"),
	translate("用户名，一般为学号，如果是新生且无学号，用户名一般为ZK开头的临时账号"))
o.datatype = "string"
o.rmempty = false

o = s:taboption("basic", Value, "password", translate("密码"),
	translate("校园网密码，初始为身份证后六位"))
o.password = true
o.datatype = "string"
o.rmempty = false

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

-- ============ Tab 2：其他设置 ============
o = s:taboption("other", DummyValue, "_log_location", translate("日志文件"))
o.rawhtml = true
o.default = "<code>/var/log/zjkju-auth/auth.log</code>"
o.description = translate("默认 /var/log/zjkju-auth/auth.log。同目录下还有 status、last-url 等运行时文件")

local checkUrl    = disp.build_url("admin", "services", "zjkju-auth", "check_update")
local doUpdateUrl = disp.build_url("admin", "services", "zjkju-auth", "do_update")
local csrfToken   = disp.context.authtoken or ""

o = s:taboption("other", DummyValue, "_version_check", translate("版本更新"))
o.rawhtml = true
o.default = [=[
<div style="margin-top:4px;">
	<div style="margin-bottom:6px;">当前版本：<code>]=] .. PKG_VERSION .. [=[</code></div>
	<button type="button" class="cbi-button cbi-button-action" onclick="zjkjuCheckUpdate()">检查新版本</button>
	<span id="zjkju-update-msg" style="margin-left:10px;"></span>
</div>

<div id="zjkju-update-modal" class="zjkju-modal-overlay">
	<div class="zjkju-modal">
		<div class="zjkju-modal-header">发现新版本 <span id="zjkju-new-ver"></span></div>
		<div class="zjkju-modal-body" id="zjkju-update-body"></div>
		<div class="zjkju-modal-footer">
			<button type="button" class="cbi-button" onclick="zjkjuCloseUpdateModal()">暂不更新</button>
			<button type="button" class="cbi-button" onclick="zjkjuGoDownload()">手动下载</button>
			<button type="button" class="cbi-button cbi-button-action" id="zjkju-btn-do-update" onclick="zjkjuInstallUpdate()">立即更新</button>
		</div>
	</div>
</div>

<style>
.zjkju-modal-overlay { position:fixed; top:0; left:0; width:100%; height:100%; background:rgba(0,0,0,.5); z-index:9999; display:none; }
.zjkju-modal { position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); background:#fff; width:90%; max-width:520px; border-radius:8px; box-shadow:0 4px 12px rgba(0,0,0,.2); }
.zjkju-modal-header { padding:14px 18px; border-bottom:1px solid #eee; font-weight:bold; }
.zjkju-modal-body { padding:16px 18px; max-height:45vh; overflow:auto; font-size:13px; color:#444; line-height:1.6; white-space:pre-wrap; word-break:break-word; }
.zjkju-modal-footer { padding:12px 18px; border-top:1px solid #eee; text-align:right; }
</style>

<script>
var zjkjuUpdateData = null;
var zjkjuCheckUrl = ']=] .. checkUrl .. [=['; 
var zjkjuDoUrl = ']=] .. doUpdateUrl .. [=['; 
var zjkjuToken = ']=] .. csrfToken .. [=['; 

window.zjkjuCheckUpdate = function() {
	var msg = document.getElementById('zjkju-update-msg');
	msg.style.color = '#888';
	msg.textContent = '正在检查更新...';
	XHR.get(zjkjuCheckUrl, null, function(x) {
		if (!x || x.status !== 200) {
			msg.style.color = '#e74c3c';
			msg.textContent = '检查失败，请检查网络';
			return;
		}
		var data;
		try { data = JSON.parse(x.responseText); }
		catch (e) { msg.style.color = '#e74c3c'; msg.textContent = '返回数据异常'; return; }
		if (data.error) {
			msg.style.color = '#e74c3c';
			msg.textContent = data.error;
		} else if (data.has_update) {
			zjkjuUpdateData = data;
			document.getElementById('zjkju-new-ver').textContent = 'v' + data.latest_version;
			document.getElementById('zjkju-update-body').textContent = data.body || '';
			document.getElementById('zjkju-update-modal').style.display = 'block';
			msg.textContent = '';
		} else {
			msg.style.color = '#2980b9';
			msg.textContent = '当前已是最新版本';
		}
	});
};

window.zjkjuCloseUpdateModal = function() {
	document.getElementById('zjkju-update-modal').style.display = 'none';
};

window.zjkjuGoDownload = function() {
	if (zjkjuUpdateData && zjkjuUpdateData.download_url) {
		window.open(zjkjuUpdateData.download_url, '_blank');
	}
	zjkjuCloseUpdateModal();
};

window.zjkjuInstallUpdate = function() {
	var btn = document.getElementById('zjkju-btn-do-update');
	if (!btn) return;
	btn.disabled = true;
	btn.textContent = '正在下载安装...';
	XHR.post(zjkjuDoUrl, { token: zjkjuToken }, function(x) {
		var res = null;
		if (x && x.status === 200) {
			try { res = JSON.parse(x.responseText); } catch (e) {}
		}
		if (res && res.success) {
			btn.textContent = '安装成功，正在刷新...';
			setTimeout(function() { window.location.reload(); }, 2500);
		} else {
			alert('安装失败: ' + (res && res.error ? res.error : '网络错误'));
			btn.disabled = false;
			btn.textContent = '重试';
		}
	});
};
</script>
]=]

-- 页面底部日志区（全局显示）
local sec = m:section(SimpleSection)
sec.template = "zjkju-auth/log"

function m.on_after_commit(self)
	local uci2 = require("luci.model.uci").cursor()
	local enabled = uci2:get("zjkju-auth", "main", "enabled")

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
