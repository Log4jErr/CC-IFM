// IFM :: web/ifm-meta.js
// 图标与物品元信息（blocksitems.com 查询与缓存）
// （由 index.html 拆分而来；所有文件按顺序在页面里加载，共享同一份全局作用域）
'use strict';

// ===================== 图标 =====================
    // 显示顺序：API 图片 → 名称兜底（中文前 4 字 / 英文各单词首字母，CDN 挂了也能看到东西）。
    // 重要：图片**不以 fetch 成功为前提** —— 页面用 file:// 打开或接口没给 CORS 头时 fetch 会失败，
    // 此时若还等元信息就会“所有图标都不显示”，所以查不到元信息时直接乐观地请求图片地址
    // （<img> 不受 CORS 限制），图片真 404 时再由 onerror 换成字形。
    const metaHints = { network: false, missing: false };   // 每类提示一次
    let fontAwesomeMissing = false;                          // Font Awesome 字体没加载成功

    function probeFontAwesome() {
        try {
            const probe = document.createElement('i');
            probe.className = 'fa fa-cube';
            probe.style.position = 'absolute';
            probe.style.left = '-9999px';
            document.body.appendChild(probe);
            const content = window.getComputedStyle(probe, '::before').content;
            document.body.removeChild(probe);
            fontAwesomeMissing = !(content && content !== 'none' && content !== 'normal');
        } catch (err) {
            fontAwesomeMissing = false;
        }
        if (fontAwesomeMissing) {
            console.warn('[IFM] Font Awesome 没加载成功（CDN 被拦截 / 离线）：工具栏图标会缺失，' +
                '资源图标改用名称兜底（见 iconFallbackText）。');
            ['resources', 'peripherals', 'processes', 'deliveries', 'machines'].forEach(markDirty);
            scheduleRender();
        }
    }

    function iconGlyphClass(kind) {
        if (kind === 'fluid') return 'fa-tint';
        if (kind === 'filter') return 'fa-filter';
        if (kind === 'placeholder') return 'fa-thumb-tack';
        if (kind === 'virtual') return 'fa-cog';
        return 'fa-cube';
    }

    // 名称兜底图标（没有图标时用名称本身当图标）：
    //   * 中文/日文等表意文字：直接取名称开头最多 4 个字（“动力合成器” → “动力合成”）
    //   * 英文：取各单词首字母，最多 4 个（“Iron Ingot” → “II”，
    //     “Purified Iron Nugget Encased Frame” → “PINE”）；只有一个单词时取前 4 个字母
    function iconFallbackText(name) {
        let label = String(name === null || name === undefined ? '' : name).trim();
        if (!label) return '?';
        // 传进来的可能是注册名（create:andesite_alloy）：只取 path 部分，别把模组名也算成首字母
        label = label.replace(/^[a-z0-9_.\-]+:/i, '');
        if (!label) return '?';
        // 表意文字（中日韩）优先：按字符截断
        if (/[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/.test(label)) {
            return label.slice(0, 4);
        }
        const words = label.split(/[\s_\-/.:]+/).filter(function (part) { return part.length > 0; });
        if (words.length === 0) return '?';
        if (words.length === 1) return words[0].slice(0, 4).toUpperCase();
        return words.slice(0, 4).map(function (word) {
            return word.charAt(0).toUpperCase();
        }).join('');
    }

    // 兜底文字用的名称：优先用界面上真正显示的名字（接口给的英文名 / 翻译后的中文名），
    // 拿不到元信息时回落到注册名的 path 部分。
    function iconLabelOf(kind, name) {
        try {
            const shown = displayName(kind, name);
            if (shown) return shown;
        } catch (err) { /* 元信息/翻译模块异常时忽略，直接用注册名兜底 */ }
        return String(name || '');
    }

    function faGlyphHtml(kind, name) {
        const text = iconFallbackText(iconLabelOf(kind, name));
        return '<span class="icon-text" data-fallback-len="' + text.length + '" title="' +
            escapeHtml(name || '') + '">' + escapeHtml(text) + '</span>';
    }

    // 元信息状态：'ready'（接口里有）/ 'missing'（接口确认没有）/ 'unknown'（还没查到）
    function metaState(key) {
        const meta = metaCache.get(key);
        if (meta === 'missing') return 'missing';
        return meta ? 'ready' : 'unknown';
    }

    function iconImgHtml(kind, name, className) {
        return '<span class="' + className + '"><img src="' + iconUrl(kind, name) + '" alt="" title="' +
            escapeHtml(name || '') + '" data-icon-key="' + escapeHtml(resourceKey(kind, name)) +
            '" onerror="window.ifmIconFallback(this, \'' + kind + '\')"></span>';
    }

    function faSpanHtml(kind, name, className) {
        return '<span class="' + className + '" title="' + escapeHtml(name || '') + '">' +
            faGlyphHtml(kind, name) + '</span>';
    }

    function iconHtml(kind, name, extraClass, forceChar) {
        const className = 'icon ' + (extraClass || '');
        const key = resourceKey(kind, name);
        const state = metaState(key);
        // 只要接口没明确说“没有这个资源”，就先请求图片：<img> 不受 CORS 限制，
        // 真正 404 时再由 onerror 换成名称兜底。
        // （以前在“元信息还没到”时会直接显示通用字形/名称，图片根本没被请求——图标看起来就是“没引用上”。）
        if (!forceChar && state !== 'missing' && !iconFailedKeys.has(key)) {
            return iconImgHtml(kind, name, className);
        }
        queueMeta(kind, name);
        return faSpanHtml(kind, name, className);
    }

    window.ifmIconFallback = function (img, kind) {
        const holder = img.parentNode;
        if (!holder) return;
        // 图片加载失败：先把这次失败记下来（见 iconFailedKeys），再换成名称兜底。
        const key = img.getAttribute('data-icon-key');
        if (key) {
            if (metaState(key) === 'unknown') {
                // 元信息还没到：这时用的图片地址是猜的，换个时机（拿到官方 icon_url 后）还能成功，
                // 所以只临时跳过图片，不写成“这个资源没有图标”。
                iconFailedKeys.add(key);
                const parts0 = splitKey(key);
                queueMeta(parts0[0] || kind || 'item', parts0[1] || '');
            } else {
                // 接口确认有这个资源、图片却下载不了：本次会话内记成“没有图标”，避免反复请求
                metaCache.set(key, 'missing');
            }
        }
        const title = img.getAttribute('title') || '';
        const parts = splitKey(key || '');
        const fallbackKind = kind || parts[0] || 'item';
        const label = title || iconLabelOf(fallbackKind, parts[1] || '');
        const text = iconFallbackText(label);
        // 没有图标就用名称兜底（中文取前 4 字；英文取各单词首字母，见 iconFallbackText）
        const replacement = document.createElement('span');
        replacement.className = 'icon-text';
        replacement.setAttribute('data-fallback-len', text.length);
        replacement.textContent = text;
        if (title) replacement.setAttribute('title', title);
        holder.replaceChild(replacement, img);
    };

    // ===================== 物品元信息（blocksitems.com） =====================
    // 说明：只有接口明确“查不到”（`found: false` 或 404）才记为“永远没有图标”；
    // 网络/限流等临时失败不写缓存，稍后重试。
    function queueMeta(kind, name) {
        if (!name) return;
        const key = resourceKey(kind, name);
        if (metaCache.has(key) || metaQueue.indexOf(key) >= 0) return;
        if ((metaRetryAt.get(key) || 0) > Date.now()) return;
        metaQueue.push(key);
        pumpMetaQueue();
    }

    function pumpMetaQueue() {
        while (metaActive < MAX_META_FETCH && metaQueue.length > 0) {
            const key = metaQueue.shift();
            if (metaCache.has(key)) continue;
            const parts = splitKey(key);
            metaActive += 1;
            fetchMeta(parts[0], parts[1]).finally(function () {
                metaActive -= 1;
                pumpMetaQueue();
            });
        }
    }

    function fetchMeta(kind, name) {
        const key = resourceKey(kind, name);
        // 用 lookup 接口（/api/v1/{items|blocks}/lookup/{full_id}）：**资源不存在时它照样返回 200**
        // （`{ found = false, data = null }`），不像 /items/{full_id} 那样报 404，
        // 所以控制台不会再刷 “item not found / OpaqueResponseBlocking”。
        return fetch(API_BASE + '/' + metaEndpoint(kind) + '/lookup/' + encodeURIComponent(name))
            .then(function (response) {
                if (response.status === 404) {
                    // 接口版本差异等情况：当作“没有这个资源”，不再反复请求
                    setMetaMissing(key);
                    return null;
                }
                if (!response.ok) throw new Error('http ' + response.status);
                return response.json();
            })
            .then(function (body) {
                if (!body) return;
                if (body.status === 'ok' && body.found && body.data) {
                    metaCache.set(key, body.data);
                    metaRetryAt.delete(key);
                    // 之前用“猜的图片地址”失败过：现在拿到官方 icon_url 了，放开让图片重试一次
                    iconFailedKeys.delete(key);
                    markDirty('resources');
                    markDirty('peripherals');
                    markDirty('machines');
                    // 立刻重画一次：图标不必等下一次服务端推送（服务端离线时也能补上图标）
                    scheduleRender();
                } else if (body.status === 'ok') {
                    // 接口里确实没有这个资源：记为“没有图标”，并写入 localStorage 免得反复请求
                    if (!metaHints.missing) {
                        metaHints.missing = true;
                        console.info('[IFM] blocksitems 接口里查不到这个资源（例如 ' + key +
                            '）：它只能使用图标库的通用字形。接口未收录的模组都是这种情况。');
                    }
                    setMetaMissing(key);
                    iconFailedKeys.delete(key);
                    // 接口明确没有这个资源：立刻重画，把图片换成名称兜底
                    scheduleRender();
                }
            })
            .catch(function (err) {
                // 网络中断 / 限流 / 5xx 等临时失败：**不**写进缓存，过一会再试
                // （否则一次抖动就会让图标永久变成缺省图标）
                metaRetryAt.set(key, Date.now() + META_RETRY_MS);
                if (!metaHints.network) {
                    metaHints.network = true;
                    console.warn('[IFM] 无法获取 blocksitems 元信息（' + ((err && err.message) || err) +
                        '）：可能是页面用 file:// 打开、接口未返回 CORS 头或离线。' +
                        '图标将直接使用图片地址，加载失败时回退成名称兜底（前 4 字 / 单词首字母）。');
                    // 已经知道 fetch 走不通：让已渲染的资源改用图片地址
                    ['resources', 'peripherals', 'processes', 'deliveries'].forEach(markDirty);
                    scheduleRender();
                }
            });
    }

    // 清空图标缓存：下次渲染会重新向接口请求（“刷新”按钮会用）
    function resetMetaCache() {
        metaCache.clear();
        metaRetryAt.clear();
        metaQueue = [];
        missingMetaKeys.clear();
        iconFailedKeys.clear();
        try { localStorage.removeItem(MISSING_META_STORAGE); } catch (err) { /* ignore */ }
    }

    // 记下“接口里没有这个资源”：本次会话不再重复请求，并写入 localStorage，
    // 下次打开页面直接使用 Font Awesome 图标，避免再产生 404
    function setMetaMissing(key) {
        metaCache.set(key, 'missing');
        if (missingMetaKeys.has(key)) return;
        missingMetaKeys.add(key);
        try {
            localStorage.setItem(MISSING_META_STORAGE, JSON.stringify(Array.from(missingMetaKeys)));
        } catch (err) { /* 隐私模式/无 localStorage 时忽略 */ }
    }

    function loadMissingMeta() {
        try {
            const raw = localStorage.getItem(MISSING_META_STORAGE);
            if (!raw) return;
            JSON.parse(raw).forEach(function (key) {
                if (typeof key === 'string' && !metaCache.has(key)) metaCache.set(key, 'missing');
            });
        } catch (err) { /* ignore */ }
    }

    
