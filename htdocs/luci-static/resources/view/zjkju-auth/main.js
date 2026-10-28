'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require request';
'require poll';

/*
 * ZJKJU 校园网认证 —— JS 视图（主界面）
 *
 * 只有 JS 视图能拿到 LuCI 原生倒计时「正在应用配置更改… Ns」：
 *   保存时改动留在暂存区 → 前端 ui.changes.apply() 接管
 *   → 倒计时 → 提交 → procd 触发器重启服务。
 *
 * 传统 Lua CBI 做不到：Map.apply() 在返回前就 commit，暂存被清空，
 * 前端 apply 只会提示「没有待应用的更改」。
 *
 * 样式与 1.0.4 系列对齐：类名、DOM、按钮样式照搬 log.htm / update.htm。
 */

var CSS_LOG = [
'.zjkju-wrapper { padding: 20px; }',
'.zjkju-toolbar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px; flex-wrap: wrap; gap: 10px; }',
'.zjkju-toolbar-left { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }',
'.zjkju-toolbar-right { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }',
'.zjkju-label { color: #666; font-size: 13px; font-weight: 500; }',
'.zjkju-badge { display: inline-block; padding: 3px 10px; border-radius: 12px; font-size: 12px; font-weight: 500; color: #fff; }',
'.zjkju-badge-online   { background: #27ae60; }',
'.zjkju-badge-offline  { background: #e74c3c; }',
'.zjkju-badge-unknown  { background: #95a5a6; }',
'.zjkju-badge-stopped  { background: #7f8c8d; }',
'.zjkju-badge-disabled { background: #6c757d; }',
'.zjkju-badge-cooling  { background: #f39c12; }',
'.zjkju-status-time { font-size: 12px; color: #888; white-space: nowrap; }',
'.zjkju-log-box { background: #1e1e1e; color: #d4d4d4; font-family: Menlo, Consolas, Monaco, monospace;',
'  font-size: 12px; line-height: 1.5; padding: 12px; border-radius: 6px; height: 400px;',
'  overflow-y: auto; overflow-x: hidden; white-space: pre-wrap; word-break: break-all; margin: 0; }',
'.zjkju-btn { display: inline-flex; align-items: center; justify-content: center; padding: 8px 18px;',
'  background: #2f80ed; color: #fff; border: none; border-radius: 8px; cursor: pointer; font-size: 13px;',
'  font-weight: 500; white-space: nowrap; letter-spacing: 0.3px;',
'  box-shadow: 0 1px 3px rgba(47, 128, 237, 0.2); transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1); user-select: none; }',
'.zjkju-btn:hover { background: #1c6dd0; box-shadow: 0 4px 10px rgba(47, 128, 237, 0.35); transform: translateY(-1px); }',
'.zjkju-btn:active { background: #155bb5; box-shadow: 0 1px 2px rgba(47, 128, 237, 0.3); transform: translateY(0); }',
'.zjkju-btn:focus { outline: none; box-shadow: 0 0 0 3px rgba(47, 128, 237, 0.25); }',
'.zjkju-btn-danger { background: #e74c3c; box-shadow: 0 1px 3px rgba(231, 76, 60, 0.2); }',
'.zjkju-btn-danger:hover { background: #c0392b; box-shadow: 0 4px 10px rgba(231, 76, 60, 0.35); transform: translateY(-1px); }',
'.zjkju-btn-danger:active { background: #a93226; box-shadow: 0 1px 2px rgba(231, 76, 60, 0.3); transform: translateY(0); }',
'.zjkju-btn-danger:focus { box-shadow: 0 0 0 3px rgba(231, 76, 60, 0.25); }'
].join('\n');

var CSS_UPDATE = [
'.zjkju-modal-overlay { position:fixed; top:0; left:0; width:100%; height:100%; background:rgba(0,0,0,.5); z-index:9999; display:none; }',
'.zjkju-modal { position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); background:#fff; width:90%; max-width:520px; border-radius:8px; box-shadow:0 4px 12px rgba(0,0,0,.2); }',
'.zjkju-modal-header { padding:14px 18px; border-bottom:1px solid #eee; font-weight:bold; }',
'.zjkju-modal-body { padding:16px 18px; max-height:45vh; overflow:auto; font-size:13px; color:#444; line-height:1.6; white-space:pre-wrap; word-break:break-word; }',
'.zjkju-modal-footer { padding:12px 18px; border-top:1px solid #eee; text-align:right; }',
'.zjkju-modal-footer .cbi-button { width:auto !important; min-width:7em !important; white-space:nowrap !important;',
'  overflow:visible !important; text-overflow:clip !important; padding:0 14px !important; margin-left:6px; }',
'.zjkju-modal-footer #zjkju-btn-do-update { min-width:10em !important; }'
].join('\n');

var BTN_STYLE = 'position:relative;outline:none;display:inline-block!important;width:auto!important;' +
	'min-width:0!important;max-width:100%!important;height:auto!important;min-height:0!important;' +
	'line-height:1.5!important;padding:6px 16px!important;margin:0!important;font-size:13px!important;' +
	'box-sizing:border-box!important';

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
	var logBox   = E('pre',  { 'class': 'zjkju-log-box', 'id': 'zjkju-log' }, [ _('（暂无日志，服务可能还未启动过）') ]);
	var netBadge = E('span', { 'class': 'zjkju-badge zjkju-badge-unknown', 'id': 'zjkju-status-badge' }, [ _('检测中') ]);
	var dmnBadge = E('span', { 'class': 'zjkju-badge zjkju-badge-unknown', 'id': 'zjkju-daemon-badge' }, [ _('检测中') ]);
	var tmSpan   = E('span', { 'class': 'zjkju-status-time', 'id': 'zjkju-status-time', 'style': 'margin-left: 12px;' }, []);

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
			if (d.running) setBadge(dmnBadge, _('运行中'), 'zjkju-badge-online');
			else           setBadge(dmnBadge, _('未运行'), 'zjkju-badge-stopped');

			if (d.enabled !== '1')            setBadge(netBadge, _('已禁用'), 'zjkju-badge-disabled');
			else if (!d.running)              setBadge(netBadge, _('未运行'), 'zjkju-badge-stopped');
			else if (d.status === 'noconfig') setBadge(netBadge, _('未配置'), 'zjkju-badge-unknown');
			else if (d.status === 'cooling')  setBadge(netBadge, _('冷却中'), 'zjkju-badge-cooling');
			else if (d.online)                setBadge(netBadge, _('在线'), 'zjkju-badge-online');
			else                              setBadge(netBadge, _('离线'), 'zjkju-badge-offline');

			tmSpan.textContent = _('状态更新') + ': ' + nowStr();
		}).catch(function() {
			setBadge(netBadge, _('未知'), 'zjkju-badge-unknown');
			setBadge(dmnBadge, _('未知'), 'zjkju-badge-unknown');
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
			logBox.textContent = _('（日志文件已被物理清空）');
		}).catch(function() {});
	};

	poll.add(function() { refreshStatus(); }, 5);
	poll.add(function() { refreshLog(); }, 10);
	window.setTimeout(function() { refreshLog(); refreshStatus(); }, 100);

	return E('div', { 'class': 'cbi-section' }, [
		E('div', { 'class': 'zjkju-wrapper' }, [
			E('div', { 'class': 'zjkju-toolbar' }, [
				E('div', { 'class': 'zjkju-toolbar-left' }, [
					E('span', { 'class': 'zjkju-label' }, [ _('当前状态') + ':' ]), ' ',
					netBadge,
					E('span', { 'class': 'zjkju-label', 'style': 'margin-left: 12px;' }, [ _('服务进程') + ':' ]), ' ',
					dmnBadge,
					tmSpan
				]),
				E('div', { 'class': 'zjkju-toolbar-right' }, [
					E('button', { 'class': 'zjkju-btn', 'click': function() { window.zjkjuRefresh(); } }, [ _('立即刷新') ]),
					E('button', { 'class': 'zjkju-btn', 'click': function() { window.zjkjuRestart(); } }, [ _('重启服务') ]),
					E('button', { 'class': 'zjkju-btn zjkju-btn-danger', 'click': function() { window.zjkjuClearLog(); } }, [ _('清空日志') ])
				])
			]),
			logBox
		])
	]);
}

function versionNode() {
	var verText = E('code', {}, [ '-' ]);
	var msgSpan = E('span', { 'id': 'zjkju-update-msg', 'style': 'margin-left:10px;' }, []);
	var dot = E('span', {
		'id': 'zjkju-red-dot',
		'style': 'display:none;position:absolute;top:-4px;right:-4px;width:10px;height:10px;' +
		         'background-color:#e74c3c;border-radius:50%;box-shadow:0 0 0 2px #fff;'
	}, []);

	return E('div', { 'style': 'margin-top:4px;' }, [
		E('div', { 'style': 'margin-bottom:6px;' }, [ _('当前版本') + '：', verText ]),
		E('span', { 'style': 'display:inline-block;' }, [
			E('button', {
				'type': 'button',
				'class': 'cbi-button cbi-button-action',
				'style': BTN_STYLE,
				'click': function() { window.zjkjuCheckUpdate(); }
			}, [ _('检查更新'), dot ])
		]), ' ',
		msgSpan
	]);
}

function renderUpdatePanel() {
	var newVer = E('span', { 'id': 'zjkju-new-ver' }, []);
	var bodyEl = E('div',  { 'class': 'zjkju-modal-body', 'id': 'zjkju-update-body' }, []);

	var btnCancel = E('button', { 'class': 'cbi-button', 'id': 'zjkju-btn-cancel-update' }, [ _('暂不更新') ]);
	var btnManual = E('button', { 'class': 'cbi-button', 'id': 'zjkju-btn-manual-download' }, [ _('手动下载') ]);
	var btnDo     = E('button', { 'class': 'cbi-button cbi-button-action', 'id': 'zjkju-btn-do-update' }, [ _('立即更新') ]);

	var modal = E('div', { 'class': 'zjkju-modal-overlay', 'id': 'zjkju-update-modal' }, [
		E('div', { 'class': 'zjkju-modal' }, [
			E('div', { 'class': 'zjkju-modal-header' }, [ _('发现新版本') + ' ', newVer ]),
			bodyEl,
			E('div', { 'class': 'zjkju-modal-footer' }, [ btnCancel, btnManual, btnDo ])
		])
	]);

	var data = null;

	btnCancel.addEventListener('click', function() { modal.style.display = 'none'; });

	btnManual.addEventListener('click', function() {
		if (data && data.download_url) window.open(data.download_url, '_blank');
		modal.style.display = 'none';
	});

	function unlock(text) {
		btnDo.disabled = false;
		btnCancel.disabled = false;
		btnManual.disabled = false;
		btnDo.textContent = text;
	}

	btnDo.addEventListener('click', function() {
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
	});

	function setMsg(text, color) {
		var el = document.getElementById('zjkju-update-msg');
		if (el) { el.style.color = color || '#888'; el.textContent = text || ''; }
	}

	window.zjkjuCheckUpdate = function() {
		setMsg(_('正在检查更新...'), '#888');

		request.request(api().check).then(function(r) {
			if (r.status !== 200) throw new Error('HTTP ' + r.status);
			return r.json();
		}).then(function(d) {
			if (d.error) {
				setMsg(d.error, '#e74c3c');
			} else if (d.has_update) {
				data = d;
				newVer.textContent = 'v' + d.latest_version;
				bodyEl.textContent = d.body || '';
				modal.style.display = 'block';
				setMsg('', '#888');
			} else {
				setMsg(_('当前已是最新版本'), '#2980b9');
			}
		}).catch(function() {
			setMsg(_('检查失败，请检查网络'), '#e74c3c');
		});
	};

	return E('div', {}, [ modal ]);
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
			_('用户名，一般为学号，如果是新生且无学号，用户名一般为ZK开头的临时账号'));
		o.rmempty = true;

		o = s.taboption('basic', form.Value, 'password', _('密码'),
			_('密码，初始为身份证后六位'));
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
		o.description = _('日志统一写入系统日志，同时双写到本地文件。同目录下还有 status、last-url 等运行时文件。');

		o = s.taboption('other', form.DummyValue, '_version_check', _('版本更新'));
		o.rawhtml = true;
		o.cfgvalue = function() { return versionNode(); };

		return Promise.resolve(m.render()).then(function(node) {
			var root = E('div', {}, [
				E('style', {}, [ CSS_LOG + '\n' + CSS_UPDATE ]),
				node
			]);
			root.appendChild(renderLogPanel());
			root.appendChild(renderUpdatePanel());
			return root;
		});
	}
});
