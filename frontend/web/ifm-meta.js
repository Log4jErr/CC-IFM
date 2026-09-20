// IFM :: web/ifm-meta.js
// 图标与物品元信息（blocksitems.com 查询与缓存）
// （由 index.html 拆分而来；所有文件按顺序在页面里加载，共享同一份全局作用域）
'use strict';

// ===================== 图标 =====================
    // 显示顺序：API 图片 → 名称兜底（中文前 4 字 / 英文各单词首字母，CDN 挂了也能看到东西）。
    // 重要：图片不以 fetch 成功为前提 —— 页面用 file:// 打开或接口没给 CORS 头时 fetch 会失败，
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
        if (kind === 'abstract') return 'fa-cog';
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
        // 不再写 title：图标上的注册名原生提示会与自定义悬停详情（.icon-tooltip）重复出现
        // （用户第 2 项要求：移除多余的注册名提示）
        return '<span class="icon-text" data-fallback-len="' + text.length + '">' + escapeHtml(text) + '</span>';
    }

    // 元信息状态：'ready'（接口里有）/ 'missing'（接口确认没有）/ 'unknown'（还没查到）
    function metaState(key) {
        const meta = metaCache.get(key);
        if (meta === 'missing') return 'missing';
        return meta ? 'ready' : 'unknown';
    }

    // 图标 <img> 本体（不含外层 span）：所有渲染路径（资源网格主图标 / 库存弹窗 / 编辑器元素行 /
    // 流程图节点 / 外设方块卡）都从这里出图，优先级固定为
    //   ① icon-exports 本地导出图（离线可用、与游戏里一致；与界面语言无关）
    //   ② blocksitems 接口图标
    // 加载失败时由 ifmIconFallback 按 data-icon-tier 继续往下退：导出图打不开 → 先把 src 换成接口地址；
    // 接口也没有 → 换成名称兜底（iconFallbackText）。
    // 以前第 ① 层只接在 plainIconImg 那一条路上，资源网格的主图标走的是 iconHtml → iconUrl（接口），
    // 于是 laowu:cat_fur 这类“接口没收录的模组”的本地导出图（laowu__cat_fur.png）根本没被引用。
    // exportedFile：调用方已经查过导出文件名时可以传进来（'' / null = 确定没有，不再重查）。
    // 索引还在加载（既没成功、也没失败）时，**先不要去请求 blocksitems 的图标**：
    // 用户看到的现象就是"明明 icon-exports 里有图，却刷了一大堆接口图标请求"。
    // 先画一个 1×1 占位图，等索引就绪后界面会整体重画（见 loadIconExports 的重画），那时才是真实图标。
    const ICON_LAZY_PLACEHOLDER = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
    function iconExportPending() {
        return !iconExportIndex && !iconExportUnavailable && !!iconExportLoadingLang;
    }

    function iconImgTagHtml(kind, name, extraAttrs, exportedFile) {
        const file = (exportedFile === undefined) ? iconExportFile(kind, name) : exportedFile;
        const pending = !file && iconExportPending();
        const src = file ? iconExportUrl(file) : (pending ? ICON_LAZY_PLACEHOLDER : iconUrl(kind, name));
        return '<img src="' + src + '" alt="" data-icon-key="' + escapeHtml(resourceKey(kind, name)) +
            '" data-icon-tier="' + (file ? 'export' : (pending ? 'lazy' : 'api')) + '"' + (extraAttrs || '') +
            ' onerror="window.ifmIconFallback(this, \'' + kind + '\')">';
    }

    function iconImgHtml(kind, name, className, exportedFile) {
        // 同上：图标上不再挂注册名的原生 title（避免与自定义悬停详情重复）
        return '<span class="' + className + '">' + iconImgTagHtml(kind, name, '', exportedFile) + '</span>';
    }

    function faSpanHtml(kind, name, className) {
        return '<span class="' + className + '">' + faGlyphHtml(kind, name) + '</span>';
    }

    function iconHtml(kind, name, extraClass, forceChar) {
        const className = 'icon ' + (extraClass || '');
        const key = resourceKey(kind, name);
        const state = metaState(key);
        // ① 本地导出图（icon-exports）永远优先：接口没收录（state === 'missing'）或者接口图
        // 曾经 404（iconFailedKeys）都不该挡住它 —— 以前的判断只看接口状态，导出图根本没有机会被引用。
        const exported = forceChar ? null : iconExportFile(kind, name);
        // ② 接口没明确说“没有这个资源”，就先请求图片：<img> 不受 CORS 限制，
        // 真正 404 时再由 onerror 换成名称兜底。
        // （以前在“元信息还没到”时会直接显示通用字形/名称，图片根本没被请求——图标看起来就是“没引用上”。）
        if (!forceChar && (exported || (state !== 'missing' && !iconFailedKeys.has(key)))) {
            return iconImgHtml(kind, name, className, exported);
        }
        queueMeta(kind, name);
        return faSpanHtml(kind, name, className);
    }

    window.ifmIconFallback = function (img, kind) {
        const holder = img.parentNode;
        if (!holder) return;
        const tier = img.getAttribute('data-icon-tier') || '';
        // 第 ① 层（icon-exports 本地图片）打不开：先试同一注册名下的另一张导出图（NBT 变体），
        // 全都打不开才退到第 ② 层（blocksitems 接口），别直接掉到名称兜底
        // （本地导出可能缺这一条，但接口有）。
        if (tier === 'export') {
            const key = img.getAttribute('data-icon-key') || '';
            const parts1 = splitKey(key);
            const failedFile = iconExportFileFromUrl(img.getAttribute('src'));
            const resourceKind = kind || parts1[0] || 'item';
            const resourceName = parts1[1] || '';
            const listed = iconExportListedFile(resourceKind, resourceName);
            iconExportMarkFailed(failedFile);
            // 同一个注册名下还有别的变体可用（图标文件在，只是 NBT 不一样）就换那一张：
            // 这样“注册名相同、NBT 不同”的物品依然用本地导出图，不会回退到 blocksitems
            const nextFile = iconExportFile(resourceKind, resourceName);
            console.info('[IFM] icon-exports 图片加载失败：' + failedFile +
                (listed ? '（元数据里登记了这张图，但该文件不在 icon-exports/ 里：导出可能不完整）'
                    : '（元数据里没有这条，用约定名猜的）') +
                (nextFile ? ' → 改用同一注册名的另一张导出图：' + nextFile
                    : ' → 退回 blocksitems 接口：' + resourceKind + ':' + resourceName));
            if (nextFile) {
                img.setAttribute('src', iconExportUrl(nextFile));     // tier 仍是 export
                return;
            }
            img.setAttribute('data-icon-tier', 'api');
            img.setAttribute('src', iconUrl(resourceKind, resourceName));
            return;
        }
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
        // 用 lookup 接口（/api/v1/{items|blocks}/lookup/{full_id}）：资源不存在时它照样返回 200
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
                // 网络中断 / 限流 / 5xx 等临时失败：不写进缓存，过一会再试
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
        // icon-exports 也一起重来（刷新按钮 = 重新拉一次当前语言的本地导出元数据）
        iconExportIndex = null;
        iconExportIndexLang = null;
        iconExportUnavailable = false;
        iconExportLoadingLang = null;
        Object.keys(iconExportLangCache).forEach(function (code) { delete iconExportLangCache[code]; });
        iconExportFailedFiles.clear();
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

    // ===================== icon-exports（本地图标导出，任务 8 / 1.6.13）=====================
    // 三层优先级：① icon-exports（本地导出的图片 + 元数据）→ ② blocksitems 接口 → ③ Bergamot 翻译/名称字形兜底。
    //
    // 元数据按语言分文件：icon-exports-metadata/<lang>.json（例如 zh.json）。
    //   * 图标：始终优先用 icon-exports（与语言无关）。当前语言的文件不存在时，会借其它语言
    //     的那份来建“图标索引”（只借图片，不借名字）。
    //   * 物品名称：只有当当前语言的元数据文件存在时才用（用户第 1 项要求）。
    //   * 切换界面语言时会自动重新加载对应语言的文件（重画时发现语言不一致就会重载）。
    // 懒加载：元数据单文件好几 MB / 近 2 万条，开局同步解析会明显拖慢首屏；
    // 页面起来之后后台抓一次、建索引，抓完重画一次（那之前先用接口图标）。
    const ICON_EXPORTS_BASE = 'icon-exports/';
    const ICON_EXPORTS_META_DIR = 'icon-exports-metadata/';
    // 部署时目录名不一定完全一致（导出工具 / 手工改名）：按顺序都试一遍，第一个能用的生效。
    // 每个目录里都是 <lang>.json（如 zh.json）；找不到就继续下一个，全都不行才彻底降级。
    const ICON_EXPORTS_META_DIRS = ['icon-exports-metadata/', 'icon-export-metadata/', 'icon-exports-metadata', 'icon-exports/'];
    const ICON_EXPORT_LANGS = ['zh', 'en'];
    let iconExportIndex = null;          // 当前展示用的索引（图标来源）
    let iconExportIndexLang = null;      // 这份索引是哪门语言的元数据（决定名字能不能用）
    let iconExportLoadingLang = null;    // 正在加载的语言（避免重复请求）
    let iconExportUnavailable = false;   // 所有语言的文件都不存在 → 整条链路退回接口图标
    const iconExportLangCache = {};      // lang -> { index: Map } / { failed: true }（含负缓存）
    const iconExportFailedFiles = new Set();   // 已 404 的导出图片（避免反复请求）

    function iconExportUrl(file) {
        // 文件名里可能有 `{ } ' , # ?` 等字符（带 components 的变体）：其中 `#` / `?` 会把 URL 截断，
        // 必须先转义，否则浏览器请求的是另一个路径（表现就是“这张图明明有，却没取到”）。
        const name = String(file || '');
        return ICON_EXPORTS_BASE +
            encodeURI(name).replace(/#/g, '%23').replace(/\?/g, '%3F');
    }

    /// 从 <img src="icon-exports/....png"> 还原出元数据里的原始文件名。
    /// 用途：`iconExportFailedFiles` 的键是原始文件名，而 URL 是编码过的 ——
    /// 以前只把 %23/%3F 还原，`{ } [ ]` 仍然是 %7B/%7D/%5B/%5D，于是“刚 404 过的图”对不上，
    /// 每次重画都会再请求一次必然 404 的图片（带 components 的长文件名 v 变体全是这种）。
    function iconExportFileFromUrl(src) {
        const encoded = String(src || '').replace(ICON_EXPORTS_BASE, '');
        try {
            return decodeURIComponent(encoded);
        } catch (err) {
            // 不是合法的转义序列（极端情况）：按原样返回，至少不会抛异常
            return encoded;
        }
    }

    /// 索引键：统一小写（导出工具的大小写不一定和游戏里一致，实测有 id 大小写不匹配的先例）
    function iconExportKey(kind, name) {
        return (kind === 'fluid' ? 'fluid' : 'item') + '|' + String(name || '').toLowerCase();
    }

    /// 导出文件名的约定：`<命名空间>__<路径>.png`（`:` 与 `/` 都写成 `__`）
    /// 元数据里没有这个物品时（导出工具漏登记 / 元数据是旧的），用它猜一个名字直接请求图片 ——
    /// “图标始终优先 icon-exports”，猜错也只是 404 一次（会被记下来，随后退回接口图标）。
    function iconExportConventionalFile(kind, name) {
        const text = String(name || '');
        if (!text) return null;
        const colon = text.indexOf(':');
        const namespace = (colon >= 0 ? text.slice(0, colon) : 'minecraft').toLowerCase();
        const path = (colon >= 0 ? text.slice(colon + 1) : text).toLowerCase();
        if (!path) return null;
        // 流体的导出文件名带 fluid__ 前缀（物品没有）：fluid__create_dragons_plus__magenta_dye.png
        const prefix = (kind === 'fluid') ? 'fluid__' : '';
        return prefix + namespace + '__' + path.replace(/\//g, '__') + '.png';
    }

    /// 语言顺序：当前界面语言优先，其次是其它语言（其它语言只用来拿图标）
    function iconExportLanguageOrder() {
        const first = (lang === 'en') ? 'en' : 'zh';
        return [first].concat(ICON_EXPORT_LANGS.filter(function (code) { return code !== first; }));
    }

    // 导出的物品名只在当前语言下使用（名字与语言相关）；乱码（含 U+FFFD）一律不用
    // 导出物品名：只用当前语言那份元数据里的名字（见 iconExportName 的语言检查）。
    // 以前要求“必须含中文”才采用，结果 en.json 的名字和没汉化的模组名全被丢掉、
    // 只能退回注册名去下划线 —— 现在只挡乱码（U+FFFD）。
    function iconExportUsableName(text) {
        const value = String(text || '').trim();
        if (!value || value.indexOf('\ufffd') >= 0) return '';
        return value;
    }

    // components（NBT）比较用的键：键顺序无关，否则游戏侧 { "a":1, "b":2 } 与导出侧
    // { "b":2, "a":1 } 会被当成两个不同的变体，NBT 物品就永远匹配不上它的专属图标。
    // 注意排序必须递归：以前只排顶层键，嵌套对象（minecraft:custom_data 里的字段就是嵌套的）
    // 仍按原顺序进字符串，同一份 NBT 只要嵌套键顺序不同就匹配不上（于是随便挑了别的变体）。
    // 数组顺序保留（数组是有序的，打乱就改变了语义）。
    function iconExportCanonical(value) {
        if (Array.isArray(value)) {
            return value.map(iconExportCanonical);
        }
        if (value && typeof value === 'object') {
            const sorted = {};
            Object.keys(value).sort().forEach(function (key) { sorted[key] = iconExportCanonical(value[key]); });
            return sorted;
        }
        return value;
    }

    function iconExportComponentsKey(components) {
        if (!components || typeof components !== 'object') return '';
        try {
            return JSON.stringify(iconExportCanonical(components));
        } catch (err) {
            return '';
        }
    }

    /// 一份 components 的“形状”：把嵌套结构摊平成
    ///   keys   = 键路径（'a.b'，不含值）
    ///   leaves = 键路径 + 值（'a.b=1'）
    /// 只用于给“NBT 最接近”的变体排序，不参与“完全一致”的判定（那由 components 键负责）。
    function iconExportComponentShape(components) {
        const shape = { keys: [], leaves: [] };
        const walk = function (node, prefix) {
            if (Array.isArray(node)) {
                if (node.length === 0) { shape.keys.push(prefix); shape.leaves.push(prefix); return; }
                node.forEach(function (item, index) { walk(item, prefix + '[' + index + ']'); });
                return;
            }
            if (node && typeof node === 'object') {
                const names = Object.keys(node);
                if (names.length === 0) { shape.keys.push(prefix); shape.leaves.push(prefix); return; }
                names.forEach(function (name) { walk(node[name], prefix + '.' + name); });
                return;
            }
            shape.keys.push(prefix);
            shape.leaves.push(prefix + '=' + String(node));
        };
        if (!components || typeof components !== 'object') return shape;
        try {
            walk(iconExportCanonical(components), '');
        } catch (err) {
            return { keys: [], leaves: [] };
        }
        return shape;
    }

    /// 两份 NBT 有多像（0~1）：键与值都相同的叶子占比为主，只有键相同（值不一样）的占比为辅 ——
    /// 同一种物品的若干变体往往只差少数叶子（耐久、颜色、槽位数…），
    /// 这样“只差一点点”的那条会排在前面；两条完全一样时得 1（等于完全一致）。
    function iconExportSimilarity(wanted, candidate) {
        if (!wanted || !candidate || wanted.leaves.length === 0 || candidate.leaves.length === 0) return 0;
        const candidateLeaves = new Set(candidate.leaves);
        const candidateKeys = new Set(candidate.keys);
        let sameLeaves = 0;
        let sameKeys = 0;
        wanted.leaves.forEach(function (leaf) { if (candidateLeaves.has(leaf)) sameLeaves += 1; });
        wanted.keys.forEach(function (key) { if (candidateKeys.has(key)) sameKeys += 1; });
        return (sameLeaves + 0.5 * sameKeys) / (wanted.leaves.length * 1.5);
    }

    /// 变体优先级：先在同一个注册名下面挑“NBT 最接近”的那条变体：
    ///   ① components 完全一致（递归比较、键顺序无关）→ 就是它；
    ///   ② 没有完全一致的：按 NBT 相似度（见 iconExportSimilarity）从高到低；
    ///   ③ 调用方根本不知道物品的 NBT（拿不到 components）：按元数据里的登记顺序。
    /// 换句话说：只要 item-metadata（icon-exports-metadata/<lang>.json）里有这个注册名，
    /// 就一定用它的图标 —— 即使 NBT 不同也不会回退到 blocksitems。
    function iconExportOrderedVariants(record, wantedKey) {
        const list = record.variants.slice();
        if (!wantedKey || list.length <= 1) return list;
        let exact = -1;
        for (let i = 0; i < list.length; i += 1) {
            if (list[i].components === wantedKey) { exact = i; break; }
        }
        if (exact === 0) return list;
        if (exact > 0) {
            list.unshift(list.splice(exact, 1)[0]);
            return list;
        }
        // 没有完全一致的：按“最接近”排序（每条变体的形状只算一次，重画时不用重算）
        const wantedShape = iconExportComponentShape(JSON.parse(wantedKey));
        const scored = list.map(function (variant, index) {
            if (!variant.shape) variant.shape = iconExportComponentShape(JSON.parse(variant.components));
            return { variant: variant, index: index,
                score: iconExportSimilarity(wantedShape, variant.shape) };
        });
        scored.sort(function (a, b) { return (b.score - a.score) || (a.index - b.index); });
        return scored.map(function (item) { return item.variant; });
    }

    /// 一个注册名下的导出图片候选（按优先级）：NBT 变体（最接近的在前）→ 无 components 的那条
    function iconExportCandidateFiles(record, wantedKey) {
        const files = [];
        const push = function (file) {
            if (file && files.indexOf(file) < 0) files.push(file);
        };
        if (wantedKey) {
            // 知道物品的 NBT：变体（完全一致或最接近）优先，通用图标垫底
            iconExportOrderedVariants(record, wantedKey).forEach(function (variant) { push(variant.file); });
            push(record.plain);
        } else {
            // 不知道 NBT（资源网格只有注册名）：先通用图标，再按登记顺序挑一条变体 ——
            // 反正都是同一个注册名的物品，比回退到 blocksitems 准。
            push(record.plain);
            iconExportOrderedVariants(record, '').forEach(function (variant) { push(variant.file); });
        }
        return files;
    }

    function buildIconExportIndex(meta, metaLang) {
        const index = new Map();
        // 路径 → 注册名（用于把不带命名空间的外设名还原成方块 id，见 blockIdCandidates）：
        //   basin → ['create:basin'] / chest → ['minecraft:chest']
        // 只有唯一命中时才用它（多个模组都有同名方块时宁可不猜，免得挂错图标）。
        const byPath = new Map();
        meta.forEach(function (entry) {
            if (!entry || !entry.id || !entry.image_file) return;
            const kind = entry.type === 'fluid' ? 'fluid' : 'item';
            const key = iconExportKey(kind, entry.id);
            let record = index.get(key);
            if (!record) {
                record = { plain: null, variants: [] };
                index.set(key, record);
            }
            const name = iconExportUsableName(entry.local_name);
            if (name && !record.name) record.name = name;
            const components = iconExportComponentsKey(entry.components);
            if (components) record.variants.push({ components: components, file: entry.image_file });
            else if (!record.plain) record.plain = entry.image_file;
            if (kind === 'item') {
                const path = String(entry.id).split(':').pop().toLowerCase();
                const ids = byPath.get(path);
                if (!ids) byPath.set(path, [String(entry.id)]);
                else if (ids.indexOf(String(entry.id)) < 0) ids.push(String(entry.id));
            }
        });
        index.lang = metaLang;      // 记住这份索引来自哪门语言（名字是否可用要看它）
        index.byPath = byPath;
        return index;
    }

    /// 本地导出里路径与给定名字相同、且只命中一个命名空间时的注册名（否则返回 ''）：
    /// CC:T 报出的外设名可能不带命名空间（basin_0），靠它把命名空间找回来（create:basin）。
    function iconExportUniqueIdByPath(path) {
        if (!ensureIconExports() || !iconExportIndex.byPath) return '';
        const ids = iconExportIndex.byPath.get(String(path || '').toLowerCase());
        return (ids && ids.length === 1) ? ids[0] : '';
    }

    function loadIconExports() {
        if (iconExportUnavailable) return;
        const wanted = (lang === 'en') ? 'en' : 'zh';
        const current = iconExportLangCache[wanted];
        if (current && current.index) {          // 当前语言的已经拿过：直接切过去（不再下载）
            iconExportIndex = current.index;
            iconExportIndexLang = wanted;
            return;
        }
        if (current && current.failed) return;   // 当前语言确认没有这个文件：保持现状（借别的语言的图标）
        if (iconExportLoadingLang) return;       // 正在加载，别重复请求

        // 请求顺序：当前语言优先，其次其它语言（其它语言只借图标）；
        // 已经拿过/确认没有的语言直接跳过 —— 这样“当前语言没有元数据文件”不会每次重画都重新下载一遍。
        const order = iconExportLanguageOrder().filter(function (code) {
            const cached = iconExportLangCache[code];
            return !(cached && (cached.index || cached.failed));
        });
        if (order.length === 0) {
            iconExportUnavailable = true;
            console.info('[IFM] 没有可用的 icon-exports 元数据（' + ICON_EXPORTS_META_DIR +
                iconExportLanguageOrder().join('.json / ') + '.json）：图标继续用 blocksitems 接口 / 名称兜底');
            return;
        }

        const tryLanguage = function (position) {
            if (position >= order.length) {
                iconExportLoadingLang = null;
                return;
            }
            const code = order[position];
            iconExportLoadingLang = code;
            // 目录名可能有多种写法（部署差异）：逐个试，找到第一个能用的就停
            const tryDir = function (dirIndex) {
                if (dirIndex >= ICON_EXPORTS_META_DIRS.length) {
                    iconExportLangCache[code] = { failed: true };   // 这个语言彻底没有
                    iconExportLoadingLang = null;
                    tryLanguage(position + 1);
                    return;
                }
                const url = ICON_EXPORTS_META_DIRS[dirIndex] + code + '.json';
                fetch(url)
                    .then(function (response) {
                        if (!response.ok) throw new Error('HTTP ' + response.status);
                        return response.json();
                    })
                    .then(function (body) {
                        const meta = body && asArray(body.meta);
                        if (meta.length === 0) throw new Error('metadata is empty');
                        const index = buildIconExportIndex(meta, code);
                        iconExportLangCache[code] = { index: index };
                        iconExportIndex = index;
                        iconExportIndexLang = code;
                        iconExportLoadingLang = null;
                        console.info('[IFM] icon-exports 元数据已加载：' + url + '（' + index.size + ' 个物品图标' +
                            (code === wanted ? '，物品名也用这份' : '，只借图标：当前语言没有对应文件') + '）');
                        ['resources', 'peripherals', 'processes', 'deliveries', 'machines'].forEach(markDirty);
                        scheduleRender();
                    })
                    .catch(function (err) {
                        // 这个目录不行（没文件 / 不是 JSON）：换下一个候选目录；都没有才换语言。
                        // 不写负缓存：candidate 还有机会成功，避免一次网络抖动就把整个语言判死。
                        console.info('[IFM] icon-exports 元数据不可用（' + url + '：' +
                            ((err && err.message) || err) + '），换下一个候选目录');
                        tryDir(dirIndex + 1);
                    });
            };
            tryDir(0);
        };
        tryLanguage(0);
    }

    /// 每次查图标/名字都走这里：语言变了或还没加载就顺手触发加载
    function ensureIconExports() {
        if (iconExportUnavailable) return false;
        if (!iconExportIndex || iconExportIndexLang !== ((lang === 'en') ? 'en' : 'zh')) loadIconExports();
        return !!iconExportIndex;
    }

    // 查一条导出记录：nbt 命中变体优先，其次默认（不带 components）图标
    function iconExportEntry(kind, name) {
        if (!ensureIconExports()) return null;
        const record = iconExportIndex.get(iconExportKey(kind, name));
        return record || null;
    }

    /// 元数据里登记的图片文件名（诊断用：区分“元数据漏了这条”与“磁盘上缺这张图”）
    function iconExportListedFile(kind, name) {
        const record = iconExportEntry(kind, name);
        if (!record) return null;
        return record.plain || (record.variants.length > 0 ? record.variants[0].file : null);
    }

    /// 导出的图标文件名（与语言无关，始终优先用；没有就返回 null，调用方退回接口图标）
    /// components（可选）：调用方知道的物品 NBT（components 表）。给了就按“完全一致 → 最接近”
    /// 在该注册名的变体里挑；给的不是表（例如 CC:T 只给得出 NBT 哈希字符串）就等同没给 ——
    /// 仍然用同一个注册名那一条的图标，不会因为 NBT 不同而回退到 blocksitems。
    function iconExportFile(kind, name, components) {
        const record = iconExportEntry(kind, name);
        if (record) {
            const wanted = iconExportComponentsKey(components);
            const files = iconExportCandidateFiles(record, wanted);
            // 已经 404 过的导出图跳过、试下一个候选（同名物品的其他变体），而不是直接掉到接口层：
            // 元数据登记了、磁盘上却没导出（导出不完整）时会有这种情况，见 run_icon_tests.js 的统计。
            // 否则每次重画都会再请求一次必然 404 的图片，等 onerror 才退回接口图标 ——
            // 界面看起来就是“图标一直闪不出来”。
            for (let i = 0; i < files.length; i += 1) {
                if (!iconExportFailedFiles.has(String(files[i]).toLowerCase())) return files[i];
            }
            // 这个注册名的导出图全都加载不了（本地确实没有可用图片）：允许去猜“约定名”，
            // 猜不到就返回 null 由调用方退到接口层（那是最后一层，不是“因为 NBT 不同”才退的）。
        }
        // 元数据里没有这个物品（导出工具漏登记 / 元数据比图片旧）：按约定名猜一个 ——
        // 图片真的存在就直接用（图标始终优先 icon-exports）；不存在就 404 一次并退回接口图标。
        // 只在“元数据已经加载成功”时才猜：这样没部署 icon-exports 的机器不会白刷一堆 404。
        if (iconExportIndex) {
            const guess = iconExportConventionalFile(kind, name);
            if (guess && !iconExportFailedFiles.has(guess.toLowerCase())) return guess;
        }
        return null;
    }

    /// 导出的物品名：只在当前语言的元数据文件存在时才给（否则返回 ''，交给 blocksitems / 翻译层）
    function iconExportName(kind, name, nbt) {
        const record = iconExportEntry(kind, name);
        if (!record) return '';
        if (iconExportIndexLang !== ((lang === 'en') ? 'en' : 'zh')) return '';
        return record.name || '';
    }

    // 导出图片 404 时别反复请求（但不影响接口图标：那是另一层）
    function iconExportMarkFailed(file) {
        if (file) iconExportFailedFiles.add(String(file).toLowerCase());
    }

    
