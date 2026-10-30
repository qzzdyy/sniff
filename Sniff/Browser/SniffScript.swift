import Foundation

/// 注入到网页里的嗅探脚本（Swift 原始字符串，JS 反斜杠原样保留）
/// 1. DOM 扫描：video/audio/source/img/poster/背景图
/// 2. 媒体事件钩子：play/playing/loadedmetadata 一响立刻上报
/// 3. performance 资源时间线 + PerformanceObserver：抓所有网络加载
/// 4. fetch/XHR 包装
/// 6. MutationObserver + 1s 轮询兜底
enum SniffScript {

    static func source() -> String {
        return #"""
        (function () {
        if (window.__sniffInjected) return;
        window.__sniffInjected = true;

        var seen = {};

        function abs(u) {
            if (!u) return null;
            u = String(u).trim();
            if (!u || u.indexOf('data:') === 0 || u.indexOf('blob:') === 0) return null;
            try { return new URL(u, location.href).href; } catch (e) { return null; }
        }

        // src 标记来源：dom（元素）/ xhr（网络请求）/ perf（资源时间线）/ html（源码正则）
        // 只有前三种代表「浏览器真的加载过」，html 扫出来的可能只是页面里的一张纸条
        function push(u, type, size, src) {
            u = abs(u);
            if (!u || seen[u]) return;
            seen[u] = 1;
            try {
                window.webkit.messageHandlers.sniff.postMessage({
                    url: u, type: type || '', size: size || 0, src: src || 'net'
                });
            } catch (e) {}
        }

        function scanDom() {
            try {
                var els = document.querySelectorAll('video,audio,source,img,[style*="background-image"]');
                for (var i = 0; i < els.length; i++) {
                    var el = els[i];
                    push(el.currentSrc || el.src || el.getAttribute('src'), el.tagName, 0, 'dom');
                    push(el.poster, 'img', 0, 'dom');
                    var bg = el.style && el.style.backgroundImage;
                    if (bg) {
                        var m = bg.match(/url\(["']?(.*?)["']?\)/);
                        if (m) push(m[1], 'img', 0, 'dom');
                    }
                }
            } catch (e) {}
        }

        function scanMedia() {
            try {
                var vs = document.querySelectorAll('video,audio');
                for (var i = 0; i < vs.length; i++) {
                    var v = vs[i];
                    push(v.currentSrc || v.src, v.tagName, 0, 'dom');
                    var ss = v.querySelectorAll ? v.querySelectorAll('source') : [];
                    for (var j = 0; j < ss.length; j++) push(ss[j].src, v.tagName, 0, 'dom');
                }
            } catch (e) {}
        }

        function scanPerf() {
            try {
                var perf = performance.getEntriesByType('resource');
                for (var k = 0; k < perf.length; k++) {
                    var e = perf[k];
                    push(e.name, e.initiatorType || 'net', e.transferSize || e.encodedBodySize || 0, 'perf');
                }
            } catch (e) {}
        }

        function scanAll() { scanDom(); scanMedia(); scanPerf(); }

        // 播放事件一触发立刻上报（用户点播放时就能抓到）
        try {
            var evs = ['play', 'playing', 'loadedmetadata', 'durationchange', 'canplay', 'progress'];
            for (var i = 0; i < evs.length; i++) {
                document.addEventListener(evs[i], function (e) {
                    var t = e.target;
                    if (!t) return;
                    if (t.tagName === 'VIDEO' || t.tagName === 'AUDIO') {
                        push(t.currentSrc || t.src, t.tagName, 0, 'dom');
                        var ss = t.querySelectorAll ? t.querySelectorAll('source') : [];
                        for (var j = 0; j < ss.length; j++) push(ss[j].src, t.tagName, 0, 'dom');
                    }
                }, true);
            }
        } catch (e) {}

        // 拦截 play() 调用
        try {
            var mp = HTMLMediaElement.prototype.play;
            HTMLMediaElement.prototype.play = function () {
                try { push(this.currentSrc || this.src, this.tagName, 0, 'dom'); } catch (e) {}
                return mp.apply(this, arguments);
            };
        } catch (e) {}

        var of = window.fetch;
        if (of) {
            window.fetch = function () {
                try { push(arguments[0] instanceof Request ? arguments[0].url : arguments[0], 'fetch', 0, 'xhr'); } catch (e) {}
                return of.apply(this, arguments);
            };
        }

        var oo = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function () {
            try { push(arguments[1], 'xhr', 0, 'xhr'); } catch (e) {}
            return oo.apply(this, arguments);
        };

        try {
            new PerformanceObserver(function (list) {
                var items = list.getEntries();
                for (var i = 0; i < items.length; i++) push(items[i].name, items[i].initiatorType || 'net', items[i].transferSize || 0, 'perf');
            }).observe({ entryTypes: ['resource'] });
        } catch (e) {}

        var timer = null;
        var mo = new MutationObserver(function () {
            if (timer) return;
            timer = setTimeout(function () { timer = null; scanDom(); scanMedia(); }, 500);
        });
        try {
            mo.observe(document.documentElement, {
                childList: true, subtree: true,
                attributes: true, attributeFilter: ['src', 'href', 'style']
            });
        } catch (e) {}

        setInterval(function () { scanPerf(); scanMedia(); }, 1000);
        scanAll();
        document.addEventListener('DOMContentLoaded', function () { scanAll(); });
        window.addEventListener('load', function () { scanAll(); });
        })();
        """#
    }
}
