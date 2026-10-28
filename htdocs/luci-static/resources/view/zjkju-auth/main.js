'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require request';
'require poll';

/*
 * ZJKJU 校园网认证 —— JS 视图
 *
 * 为什么用 JS 视图而不是旧式 Lua CBI：
 *   旧式 CBI 在服务端保存时就 commit，LuCI 的 ui.changes.apply() 随后找不到
 *   待应用的改动，原生「正在应用配置更改… Ns」倒计时不会出现。
 *   JS 视图走标准流程：改动先暂存 → ui.changes.apply() 应用 → 原生倒计时出现。
 *
 * 服务重启不在前端做，由 /etc/init.d/zjkju-auth 的
 * procd_add_reload_trigger("zjkju-auth") 在配置提交后自动触发。
 */

var CSS = [
'.zjkju-wrap { padding: 16px 0; }',
'.zjkju-bar { display:flex; justify-content:space-between; align-items:center; gap:10px; flex-wrap:wrap; margin-bottom:14px; }',
'.zjkju-bar-left, .zjkju-bar-right { display:flex; align-items:center; gap:8px; flex-wrap:wrap; }',
'.zjkju-lbl { color:#666; font-size:13px; font-weight:500; }',
'.zjkju-badge { display:inline-block; padding:3px 10px; border-radius:12px; font-size:12px; font-weight:500; color:#fff; }',
'.zjkju-on   { background:#27ae60; }',
'.zjkju-off  { background:#e74c3c; }',
'.zjkju-idle { background:#7f8c8d; }',
'.zjkju-dis  { background:#6c757d; }',
'.zjkju-cool { background:#f39c12; }',
'.zjkju-unk  { background:#95a5a6; }',
'.zjkju-time { font-size:12px; color:#888; white-space:nowrap; }',
'.zjkju-log { background:#1e1e1e; color:#d4d4d4; font-family:Menlo,Consolas,Monaco,monospace;',
'  font-size:12px; line-height:1.5; padding:12px; border-radius:6px; height:400px;',
'  overflow-y:auto; overflow-x:hidden; white-space:pre-wrap; word-break:break-all; margin:0; }',
'.zjkju-btn { display:inline-flex; align-items:center; justify-content:center; padding:7px 16px;',
'  background:#2f80ed; color:#fff; border:none; border-radius:8px; cursor:pointer; font-size:13px;',
'  font-weight:500; white-space:nowrap; user-select:none; }',
'.zjkju-btn:hover { background:#1c6dd0; }',
'.zjkju-btn-danger { background:#e74c3c; }',
'.zjkju-btn-danger:hover { background:#c0392b; }',
'.zjkju-modal { position:fixed; top:0; left:0; width:100%; height:100%; background:rgba(0,0,0,.5);',
'  z-index:9999; display:none; }',
'.zjkju-modal-box { position:absolute; top:50%; left:50%; transform:translate(-50%,-50%);',
'  background:#fff; width:90%; max-width:520px; border-radius:8px; box-shadow:0 4px 12px rgba(0,0,0,.2); }',
'.zjkju-modal-hd { padding:14px 18px; border-bottom:1px solid #eee; font-weight:bold; }',
'.zjkju-modal-bd { padding:16px 18px; max-height:45vh; overflow:auto; font-size:13px; color:#444;',
'  line-height:1.6; white-space:pre-wrap; word-break:break-word; }',
'.zjkju-modal-ft { padding:12px 18px; border-top:1px solid #eee; text-align:right; }',
'.zjkju-modal-ft .cbi-button { width:auto !important; min-width:7em !important; white-space:nowrap !important;',
'  overflow:visible !important; text-overflow:clip !important; padding:0 14px !important; margin-left:6px; }',
'.zjkju-modal-ft #zjkju-up-btn { min-width:10em !important; }'
].join('\n');

var URLS = null;

function api() {
	if (!URLS) {
		URLS = {
			status:   L.url('admin', 'services', 'zjkju-auth', 'status'),
			log:      L.url('admin', 'services', 'zjkju-auth', 'log'),
			restart:  L.url('admin', 'services', 'zjkju-auth', 'restart'),
			clearlog: L.url('admin', 'services', 'zjkju-auth', 'clearlog'),
			check:    L.url('admin', 'services', 'zjkju-auth', 'check_update'),
			update:   L.url('admin', 'services', 'zjkju-auth', 'do_update'),
			upstatus: L.url('admin', 'services', 'zjkju-auth', 'update_status')
		};
	}
	return URLS;
}

function setBadge(el, text, cls) {
	if (!el) return;
	el.textContent = text;
	el.className = 'zjkju-badge ' + cls;
}

function nowStr() {
	var d = new Date(), p = function(n) { return n < 10 ? '0' + n : '' + n; };
	return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

function renderLogPanel() {
	var logBox = E('pre', { 'class': 'zjkju-log', 'id': 'zjkju-log' }, [ _('加载中...') ]);
	var netBadge = E('span', { 'class': 'zjkju-badge zjkju-unk', 'id': 'zjkju-net-badge' }, [ _('检测中') ]);
	var dmnBadge = E('span', { 'class': 'zjkju-badge zjkju-unk', 'id': 'zjkju-dmn-badge' }, [ _('检测中') ]);
	var tmSpan = E('span', { 'class': 'zjkju-time', 'id': 'zjkju-ts' }, []);

	function refreshLog() {
		request.request(api().log).then(function(r) {
			if (r.status !== 200) return;
			return r.text().then(function(txt) {
				var atBottom = (logBox.scrollHeight - logBox.scrollTop - logBox.clientHeight) < 30;
				logBox.textContent = txt;
				if (atBottom) logBox.scrollTop = logBox.scrollHeight;
			});
		}).catch(function() {});
	}

	function refreshStatus() {
		request.request(api().status).then(function(r) {
			if (r.status !== 200) throw new Error('status');
			return r.json();
		}).then(function(d) {
			if (d.running) setBadge(dmnBadge, _('运行中'), 'zjkju-on');
			else           setBadge(dmnBadge, _('未运行'), 'zjkju-idle');

			if (d.enabled !== '1')        setBadge(netBadge, _('已禁用'), 'zjkju-dis');
			else if (!d.running)          setBadge(netBadge, _('未运行'), 'zjkju-idle');
			else if (d.status === 'noconfig') setBadge(netBadge, _('未配置'), 'zjkju-unk');
			else if (d.status === 'cooling')  setBadge(netBadge, _('冷却中'), 'zjkju-cool');
			else if (d.online)            setBadge(netBadge, _('在线'), 'zjkju-on');
			else                          setBadge(netBadge, _('离线'), 'zjkju-off');

			tmSpan.textContent = _('状态更新') + ': ' + nowStr();
		}).catch(function() {
			setBadge(netBadge, _('未知'), 'zjkju-unk');
			setBadge(dmnBadge, _('未知'), 'zjkju-unk');
		});
	}

	window.zjkjuRefresh = function() { refreshLog(); refreshStatus(); };

	window.zjkjuRestart = function() {
		if (!confirm(_('确定要重启认证服务吗？'))) return;
		request.request(api().restart).then(function() {
			window.setTimeout(window.zjkjuRefresh, 2000);
		}).catch(function() {});
	};

	window.zjkjuClearLog = function() {
		if (!confirm(_('确定要清空日志吗？'))) return;
		request.request(api().clearlog).then(function() {
			logBox.textContent = _('（日志文件已被清空）');
		}).catch(function() {});
	};

	poll.add(function() { refreshStatus(); }, 5);
	poll.add(function() { refreshLog(); }, 10);

	window.setTimeout(function() { refreshLog(); refreshStatus(); }, 100);

	var el = E('div', { 'class': 'cbi-section' }, [
		E('div', { 'class': 'zjkju-wrap' }, [
			E('div', { 'class': 'zjkju-bar' }, [
				E('div', { 'class': 'zjkju-bar-left' }, [
					E('span', { 'class': 'zjkju-lbl' }, [ _('当前状态') + ':' ]), ' ',
					netBadge,
					E('span', { 'class': 'zjkju-lbl', 'style': 'margin-left:12px;' }, [ _('服务进程') + ':' ]), ' ',
					dmnBadge, ' ',
					tmSpan
				]),
				E('div', { 'class': 'zjkju-bar-right' }, [
					E('button', { 'class': 'zjkju-btn', 'click': function() { window.zjkjuRefresh(); } }, [ _('立即刷新') ]),
					E('button', { 'class': 'zjkju-btn', 'click': function() { window.zjkjuRestart(); } }, [ _('重启服务') ]),
					E('button', { 'class': 'zjkju-btn zjkju-btn-danger', 'click': function() { window.zjkjuClearLog(); } }, [ _('清空日志') ])
				])
			]),
			logBox
		])
	]);

	return el;
}

function renderUpdatePanel() {
	var verText = E('code', {}, [ '-' ]);
	var msgSpan = E('span', { 'style': 'margin-left:10px;' }, []);
	var dot = E('span', {
		'id': 'zjkju-dot',
		'style': 'display:none;position:absolute;top:-4px;right:-4px;width:10px;height:10px;' +
		         'background:#e74c3c;border-radius:50%;box-shadow:0 0 0 2px #fff;'
	}, []);

	var newVer = E('span', { 'id': 'zjkju-new-ver' }, []);
	var bodyEl = E('div', { 'class': 'zjkju-modal-bd', 'id': 'zjkju-upd-body' }, []);

	var btnCancel = E('button', { 'class': 'cbi-button', 'click': function() { hideModal(); } }, [ _('暂不更新') ]);
	var btnManual = E('button', { 'class': 'cbi-button', 'click': function() { goDownload(); } }, [ _('手动下载') ]);
	var btnDo = E('button', {
		'class': 'cbi-button cbi-button-action',
		'id': 'zjkju-up-btn',
		'click': function() { doUpdate(); }
	}, [ _('立即更新') ]);

	var modal = E('div', { 'class': 'zjkju-modal', 'id': 'zjkju-upd-modal' }, [
		E('div', { 'class': 'zjkju-modal-box' }, [
			E('div', { 'class': 'zjkju-modal-hd' }, [ _('发现新版本') + ' ', newVer ]),
			bodyEl,
			E('div', { 'class': 'zjkju-modal-ft' }, [ btnCancel, btnManual, btnDo ])
		])
	]);

	var data = null;

	function showModal() { modal.style.display = 'block'; }
	function hideModal() { modal.style.display = 'none'; }

	function goDownload() {
		if (data && data.download_url) window.open(data.download_url, '_blank');
		hideModal();
	}

	function unlock(text) {
		btnDo.disabled = false;
		btnCancel.disabled = false;
		btnManual.disabled = false;
		btnDo.textContent = text;
	}

	function doUpdate() {
		btnDo.disabled = true;
		btnCancel.disabled = true;
		btnManual.disabled = true;
		btnDo.textContent = _('正在初始化...');

		request.request(api().update, {
			method: 'post',
			query: { token: L.env.token }
		}).then(function(r) {
			if (r.status !== 200) throw new Error('HTTP ' + r.status);
			return r.json();
		}).then(function(res) {
			if (res && res.success === false) {
				alert(_('更新失败') + ': ' + (res.error || _('未知错误')));
				unlock(_('立即更新'));
				return;
			}

			var timer = window.setInterval(function() {
				request.request(api().upstatus + '?t=' + Date.now()).then(function(r) {
					if (r.status !== 200) return;
					return r.text().then(function(text) {
						var p = text.split('|');
						var state = p[0], msg = p[1] || '';
						var n = parseInt((p[2] || '').replace(/[^0-9]/g, ''), 10);
						if (isNaN(n)) n = 0;
						if (n > 100) n = 100;

						if (state === '4') {
							window.clearInterval(timer);
							btnDo.textContent = _('完成，刷新中...');
							window.setTimeout(function() { window.location.reload(); }, 1000);
						} else if (state === '-1') {
							window.clearInterval(timer);
							alert(_('更新失败') + ': ' + msg);
							unlock(_('立即更新'));
						} else if (state === '1') {
							btnDo.textContent = n > 0 ? (_('下载中') + ' ' + n + '%') : _('下载中...');
						} else if (state === '2') {
							btnDo.textContent = _('校验中');
						} else if (state === '3') {
							btnDo.textContent = _('安装中');
						} else {
							btnDo.textContent = (msg || _('处理中')) + '...';
						}
					});
				}).catch(function() {});
			}, 500);
		}).catch(function(e) {
			alert(_('更新请求失败') + ': ' + e.message);
			unlock(_('立即更新'));
		});
	}

	function checkUpdate(silent) {
		if (!silent) { msgSpan.style.color = '#888'; msgSpan.textContent = _('正在检查更新...'); }

		request.request(api().check).then(function(r) {
			if (r.status !== 200) throw new Error('HTTP ' + r.status);
			return r.json();
		}).then(function(d) {
			if (d.current_version) verText.textContent = d.current_version;

			if (d.error) {
				if (!silent) { msgSpan.style.color = '#e74c3c'; msgSpan.textContent = d.error; }
			} else if (d.has_update) {
				dot.style.display = 'inline-block';
				data = d;
				newVer.textContent = 'v' + d.latest_version;
				bodyEl.textContent = d.body || '';
				if (!silent) { showModal(); msgSpan.textContent = ''; }
			} else {
				dot.style.display = 'none';
				if (!silent) { msgSpan.style.color = '#2980b9'; msgSpan.textContent = _('当前已是最新版本'); }
			}
		}).catch(function() {
			if (!silent) { msgSpan.style.color = '#e74c3c'; msgSpan.textContent = _('检查失败，请检查网络'); }
		});
	}

	window.setTimeout(function() { checkUpdate(true); }, 1500);

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, [ _('版本更新') ]),
		E('div', { 'class': 'cbi-section-node', 'style': 'padding:12px 0;' }, [
			E('div', { 'style': 'margin-bottom:10px;' }, [ _('当前版本') + '：', verText ]),
			E('span', { 'style': 'display:inline-block;' }, [
				E('button', {
					'type': 'button',
					'class': 'cbi-button cbi-button-action',
					'style': 'position:relative;outline:none;display:inline-block!important;width:auto!important;' +
					         'min-width:0!important;max-width:100%!important;height:auto!important;' +
					         'min-height:0!important;line-height:1.5!important;padding:6px 16px!important;' +
					         'margin:0!important;font-size:13px!important;box-sizing:border-box!important;',
					'click': function() { checkUpdate(false); }
				}, [ _('检查更新'), dot ])
			]), ' ',
			msgSpan
		]),
		modal
	]);
}

return view.extend({
	load: function() {
		return uci.load('zjkju-auth');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('zjkju-auth', _('ZJKJU 校园网认证'),
			_('在路由器上自动完成校园网 ePortal 认证。填写学号和密码后，勾选「启用」并保存。'));

		s = m.section(form.NamedSection, 'main', 'zjkju-auth', _('认证设置'));
		s.anonymous = true;
		s.addremove = false;

		s.tab('basic', _('认证设置'));
		s.tab('other', _('其他设置'));

		o = s.taboption('basic', form.Flag, 'enabled', _('启用'),
			_('勾选并保存后，服务会立即启动；取消勾选保存会停止服务'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'username', _('用户名'),
			_('用户名，一般为学号。清空并保存会删除该配置项。'));
		o.rmempty = true;

		o = s.taboption('basic', form.Value, 'password', _('密码'),
			_('密码，初始为身份证后六位。清空并保存会删除该配置项。'));
		o.password = true;
		o.rmempty = true;

		o = s.taboption('basic', form.ListValue, 'service', _('服务类型'),
			_('默认使用「电信校园网」，一般无需修改'));
		o.value('%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91', _('电信校园网'));
		o.default = '%E7%94%B5%E4%BF%A1%E6%A0%A1%E5%9B%AD%E7%BD%91';
		o.rmempty = false;

		o = s.taboption('basic', form.Value, 'manual_url', _('手动认证地址'),
			_('通常留空。只有自动抓取和缓存都失败时才会用到这个地址'));
		o.rmempty = true;

		o = s.taboption('other', form.Flag, 'beta_channel', _('接收测试版'),
			_('开启后会收到标为 pre-release 的版本，仅建议测试用户开启'));
		o.default = '0';
		o.rmempty = false;

		o = s.taboption('other', form.DummyValue, '_log_location', _('日志文件'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return E('code', {}, [ '/var/log/zjkju-auth/auth.log' ]);
		};
		o.description = _('日志同时写入系统日志和本地文件。同目录下还有 status、last-url 等运行时文件。');

		return Promise.resolve(m.render()).then(function(node) {
			var root = E('div', {}, [
				E('style', {}, [ CSS ]),
				node
			]);
			root.appendChild(renderLogPanel());
			root.appendChild(renderUpdatePanel());
			return root;
		});
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
