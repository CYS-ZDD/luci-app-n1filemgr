'use strict';
'require view';

// LuCI 内嵌文件管理器。
// 布局：读取主题内容区真实位置，iframe fixed 精确铺满该区域；
// 插件页打开期间锁定 html/body 滚动（避免 LuCI 蓝色标题栏随页面滚动滑走），
// 离开插件页(destroy)时自动移除锁定，不影响 LuCI 其他页面。
return (function(){
	var style = null, ro = null, resizeHandler = null;

	return view.extend({
		render: function() {
			var attached = false;
			var busy = false;
			var hostEl = null;
			var CONTENT_IDS = ['maincontent', 'maincontent-inner'];
			var HEADER_SEL = '.main-header, #header, header, .header, .navbar';

			var iframe = document.createElement('iframe');
			iframe.setAttribute('frameborder', '0');
			iframe.setAttribute('scrolling', 'no');
			iframe.src = '/luci-static/resources/n1filemgr/index.html?v=077';
			iframe.style.cssText = 'display:block;margin:0;padding:0;border:0;width:100%;height:100%;';

			var wrap = document.createElement('div');
			wrap.style.cssText = 'margin:0;padding:0;';
			wrap.appendChild(iframe);

			// 最小样式：隐藏本页不需要的底部操作栏 + 去内容区自身内边距；
			// 并锁定 html/body 滚动（仅插件页生效，destroy 时移除）
			if (!style) {
				style = document.createElement('style');
				style.textContent = '.cbi-page-actions{display:none !important;}'
					+ '#maincontent, .main-right, .cbi-map, .cbi-map-node { padding:0 !important; margin:0 !important; }'
					+ 'html, body { overflow:hidden !important; height:100% !important; }';
				document.head.appendChild(style);
			}

			function host() {
				if (hostEl && document.body.contains(hostEl))
					return hostEl;
				hostEl = null;
				for (var i = 0; i < CONTENT_IDS.length; i++) {
					var el = document.getElementById(CONTENT_IDS[i]);
					if (el) { hostEl = el; break; }
				}
				if (!hostEl)
					hostEl = document.querySelector('.main-right') || document.querySelector('.main');
				return hostEl;
			}

			function headerBottom() {
				var h = document.querySelector(HEADER_SEL);
				return h ? h.getBoundingClientRect().bottom : 0;
			}

			// 祖先元素若有 transform/filter/perspective，会成为 fixed 的包含块，
			// 此时 fixed 的坐标以该祖先为参照，需要扣掉它的原点
			function fixedOrigin() {
				var ox = 0, oy = 0, h = host();
				var el = h ? h.parentElement : null;
				while (el && el !== document.documentElement) {
					var cs = window.getComputedStyle(el);
					if (cs && (cs.transform !== 'none' || cs.filter !== 'none' || cs.perspective !== 'none')) {
						var r = el.getBoundingClientRect();
						ox = r.left; oy = r.top;
					}
					el = el.parentElement;
				}
				return { x: ox, y: oy };
			}

			function apply() {
				if (!document.body.contains(wrap)) {
					if (attached) {
						window.removeEventListener('resize', apply);
						if (ro) { ro.disconnect(); ro = null; }
					}
					return;
				}
				attached = true;
				if (busy) return;
				busy = true;

				var vw = window.innerWidth, vh = window.innerHeight;
				var box = null, h = host();
				if (h && h.getBoundingClientRect) {
					var r = h.getBoundingClientRect();
					if (r && r.width >= 200 && r.top >= 0 && r.left < vw) {
						var o = fixedOrigin();
						box = { left: Math.round(r.left - o.x), top: Math.round(r.top - o.y), width: Math.round(r.width) };
					}
				}

				if (box) {
					iframe.style.position = 'fixed';
					iframe.style.left = box.left + 'px';
					iframe.style.top = box.top + 'px';
					iframe.style.width = box.width + 'px';
					iframe.style.height = Math.max(320, vh - box.top) + 'px';
				} else {
					// 兜底：拿不到内容区就退回常规流布局，高度按顶栏以下撑满视口
					iframe.style.position = 'static';
					iframe.style.left = 'auto';
					iframe.style.top = 'auto';
					iframe.style.width = '100%';
					iframe.style.height = Math.max(320, Math.round(vh - headerBottom())) + 'px';
				}

				if (!ro && typeof window.ResizeObserver === 'function') {
					ro = new ResizeObserver(function() { apply(); });
					if (host()) ro.observe(host());
					if (document.body) ro.observe(document.body);
				}
				busy = false;
			}

			resizeHandler = apply;
			window.addEventListener('resize', apply);
			setTimeout(apply, 0);
			setTimeout(apply, 150);
			setTimeout(apply, 600);
			setTimeout(apply, 1500);   // 等主题的侧栏/过渡动画结束后再校正

			return wrap;
		},
		destroy: function() {
			if (style && style.parentNode) {
				try { style.parentNode.removeChild(style); } catch (e) {}
				style = null;
			}
			if (ro) { try { ro.disconnect(); } catch (e) {} ro = null; }
			if (resizeHandler) {
				window.removeEventListener('resize', resizeHandler);
				resizeHandler = null;
			}
		}
	});
})();
