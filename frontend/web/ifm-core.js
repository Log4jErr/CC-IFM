// IFM :: web/ifm-core.js
// 核心：常量 / 状态 / 文案(i18n) / 通用工具 / ASCII 传输编码 / 数据规范化 / 连接状态
// （由 index.html 拆分而来；所有文件按顺序在页面里加载，共享同一份全局作用域）
'use strict';




    // ===================== 常量 =====================
    // 前端版本号：必须与后端 backend/IFMMaster.lua 里的 IFM_VERSION 完全一致。
    // 连上服务端后会比对 status.version，不一致就弹警告并主动停止连接（见 ifm-net.js）。
    const IFM_CLIENT_VERSION = '1.8.2';
    const DEFAULT_RELAY = 'wss://itty.ws/c/';
    const API_BASE = 'https://blocksitems.com/api/v1';
    const API_ORIGIN = 'https://blocksitems.com';
    const MAX_META_FETCH = 6;
    const ROTATE_MS = 1000;
    // 看门狗：多久没收到“服务端数据”就认为卡住（超过 4 倍 → 回到登录页，见 ifm-app.js 的看门狗）
    const STALL_MS = 15000;

    // ===================== 状态 =====================
    const stores = {
        containers: new Map(),
        signals: new Map(),
        filters: new Map(),
        machineTypes: new Map(),
        machines: new Map(),
        processes: new Map(),
        peripherals: new Map(),
        missing: new Map(),
        resources: new Map(),
        runtime: new Map(),
        deliveries: new Map(),
        workers: new Map(),
    };


    /// 只读机器（自动生成 / 虚拟）：turtle_crafter 的海龟机器由后端自动出现 —— 不能编辑、
    /// 不能拖外设进它的输入/输出位置、里面的卡片不能删也不能拖（用户第 3 项）。
    /// ifm-app.js（拖拽 / 点击委托）与 ifm-processes.js（渲染）共用这个判定，避免两处写歪。
    function machineIsReadOnly(name) {
        const machine = stores.machines.get(String(name || ''));
        return !!(machine && machine.virtual === true);
    }

    /// 机器类型卡片是不是只读（预设类型 turtle_crafter：机器由海龟自己出现，没有人工配置）
    function machineTypeIsReadOnly(typeName) {
        return String(typeName || '') === 'turtle_crafter';
    }

    /// ===================== 抽象操作 / 抽象流程（用户第 3 项）=====================
    /// 旧概念"虚操作"（元素 kind = virtual）已移除。现在：
    ///   * 把**物品/流体**元素的注册名写成 "abstract"，这一条就是「抽象操作」——
    ///     它不对应任何真实资源，只是"这里以后要换成真实材料/产物"的占位步骤；
    ///   * 含抽象操作的流程 = 「抽象流程」：可以保存、可以作为"复制流程设置"的来源，
    ///     但不能执行 / 不能当上游 / 不能下单合成（服务端 Store.processIsAbstract 做同一判定）。
    const IFM_ABSTRACT_ID = 'abstract';

    function elementIsAbstract(element) {
        if (!element) return false;
        if (element.kind !== 'item' && element.kind !== 'fluid') return false;
        return String(element.id || '').trim().toLowerCase() === IFM_ABSTRACT_ID;
    }

    function processIsAbstract(process) {
        if (!process) return false;
        return asArray(process.inputs).concat(asArray(process.outputs)).some(elementIsAbstract);
    }
    const sendList = new Map();       // key -> { kind, name, count }
    const metaCache = new Map();      // "kind:name" -> { display_name, mod_id } | 'missing'
    const iconIndex = new Map();      // 过滤器图标轮换下标
    const nodeProcess = new Map();    // mermaid 节点 id -> 流程名
    const nodeTooltip = new Map();    // mermaid 节点 id -> { title, lines }（悬停详情）
    const pendingRequests = new Map();
    let ws = null;
    let room = '';
    let relayBase = DEFAULT_RELAY;
    let connected = false;
    // 请求序号：每个客户端一个随机起点 —— 房间里的响应是广播给所有人的，
    // 如果两个浏览器都从 1 开始编号，A 的响应会被 B 当成自己的（B 就永远“收不到响应”，
    // A 也会拿到别人的结果）。随机起点让 id 实际上不会撞车。
    let requestSeq = Math.floor(Math.random() * 0x7fffffff);
    let heartbeatTimer = null;
    let lastHeartbeatAt = 0;
    // 最近一次真的收到“服务端数据”的时间（只由 markServerSeen 更新）：
    // 看门狗用它判断“服务端是否长时间失联（4 × STALL_MS 后回到登录页）”；
    // 不能用 lastHeartbeatAt —— 重新连上中继（onopen）也会刷新它，那样永远判不出“失联”。
    let lastServerDataAt = 0;
    let lastForcedReconnectAt = 0;
    // 本次 WebSocket 连接里是否已经收到过服务端数据（决定显示“已连接”还是“连接中”）
    let serverSeen = false;
    // 本页是否曾经收到过服务端数据：决定“连上中继后能不能立刻显示主界面”。
    // 从没收到过的服务端（没在跑）：页面稳定停在登录框，等服务端真的说话再切过去，
    // 避免“登录框 ↔ 空主界面”每 20 秒来回闪一次。
    let everSeenServer = false;
    // 本次连接里是否已经提示过“收不到服务端数据”（避免看门狗每 3 秒弹一次）
    let stallNotified = false;
    let status = {};
    // 版本比对：服务端版本号 + 是否因版本不一致而停止连接（避免新旧版本混用产生怪问题）
    let serverVersion = '';
    let versionMismatch = false;
    // 资源排序模式（1.6.11）：数量降序（默认）/ 数量升序 / 字典序
    let sortMode = 'countDesc';       // countDesc | countAsc | name
    // 「外设与定义」的排序模式：peripheral（外设名字典序，默认）| block（方块名）| defs（定义数量）
    let peripheralSortMode = 'peripheral';
    let searchText = '';
    let peripheralSearchText = '';
    let dirty = {};
    let renderTimer = null;
    let metaQueue = [];
    let metaActive = 0;
    let graphRendering = false;
    let lang = 'zh';
    // 最近一次收到 status 推送的时间（用于「整理」的本地占位进度：服务端还没回传进度时先显示本地状态）
    let statusUpdatedAt = 0;
    // 点击「整理」后、服务端第一次回传进度前的本地占位状态
    let compactOptimistic = null;
    // 接口里确认“查不到”的资源键（写进 localStorage，避免每次打开页面都发一堆请求）
    // v2：旧版（v1）可能把“网络抖动导致的失败”也记成了缺失，换键名让它们自然失效
    const MISSING_META_STORAGE = 'ifm_missing_meta_v2';
    const missingMetaKeys = new Set();
    // 本次会话里“图片请求失败、但元信息还没到”的键：此时用的图片地址是猜的（/items/<id>/icon），
    // 只临时跳过图片，等元信息到了再用官方 icon_url 试一次；不写成“这个资源没有图标”。
    const iconFailedKeys = new Set();
    // 元信息请求临时失败（网络/限流）后的重试时间点
    const metaRetryAt = new Map();
    const META_RETRY_MS = 60000;

    function t(key, params) {
        const pack = I18N[lang] || I18N.zh;
        let text = pack[key] || I18N.zh[key] || key;
        if (params) {
            Object.keys(params).forEach(function (name) {
                text = text.split('{' + name + '}').join(params[name]);
            });
        }
        return text;
    }


    // ===================== 文案 =====================
    const I18N = {
        zh: {
            loginHint: '请输入与服务端相同的房间号',
            connect: '连接', disconnect: '断开', connecting: '连接中…', connected: '已连接', disconnected: '未连接',
            resources: '资源',
            search: '搜索', sendList: '待发送',
            send: '发送', processes: '进程', addProcess: '添加流程',
            deliveries: '发送中',
            peripherals: '外设与定义', container: '容器定义', signal: '信号定义',
            peripheralNameHint: '外设名',
            machines: '机器', machineType: '机器类型', machine: '机器', filter: '过滤器',
            graph: '流程依赖图', noProcess: '暂无流程定义',
            save: '保存', cancel: '取消', ok: '确定', delete: '删除', add: '添加',
            name: '名称', peripheral: '外设', role: '角色', rules: '规则', type: '类型',
            machineTypeField: '机器类型', itemInputs: '物品输入容器', fluidInputs: '流体输入容器',
            signalsField: '红石信号', itemOutputs: '物品输出容器', fluidOutputs: '流体输出容器',
            parallel: '并行信号量', maxMultiplier: '最大翻倍数', inputs: '输入材料', outputs: '输出产物',
            copyProcessFrom: '复制流程设置', copyProcessApply: '复制',
            copyProcessHint: '只能从同一个机器类型的流程复制；抽象流程优先显示（含 abstract 操作，只能用来作为被复制目标）',
            copyProcessDone: '已复制「{name}」的输入/输出设置', copyProcessNothing: '请先在下拉框里选择要复制的流程',
            copyProcessOtherType: '只能复制同一个机器类型的流程', copyProcessOnlyOne: '当前机器类型下还没有别的流程可以复制',
            // 用户第 3 项：虚操作概念已移除 —— 现在把物品/流体的注册名填成 abstract 即可（抽象操作）
            abstractProcess: '抽象流程', abstractOp: '抽象操作',
            abstractHint: '把物品/流体的注册名填成 abstract：这一条就是“抽象操作”，不对应任何真实资源；含抽象操作的流程是抽象流程 —— 不能合成，但可以保存、可以作为“复制流程设置”的来源',
            clearAbstractOps: '清除所有 abstract 操作', clearAbstractOpsHint: '把「输入材料」「输出产物」里注册名为 abstract 的物品/流体操作全部删掉',
            clearAbstractOpsDone: '已清除 {n} 条 abstract 操作', clearAbstractOpsNone: '没有找到 abstract 操作',
            ignoreNbt: '忽略 NBT', amount: '数目', min: '最少', max: '最多', priority: '优先级',
            containerIndex: '容器序号', slot: '槽位', seconds: '时长(秒)', threshold: '阈值', strength: '强度',
            op: '比较', sides: '方向', machineSignalIndex: '机器红石信号序号',
            side_top: '上', side_bottom: '下', side_left: '左', side_right: '右', side_front: '前', side_back: '后',
            signalHint: '机器红石信号序号（从 1 起始）',
            placeholder: '占位符', item: '物品', fluid: '流体', filterKind: '过滤器',
            waitSignal: '等待红石信号', emitSignal: '设置红石信号', emitPulse: '发出红石脉冲', waitTime: '等待时间',
            storage: '存储', interaction: '交互', output: '输出',
            containerKind: '容器种类', itemContainer: '物品容器', fluidContainer: '流体容器',
            storageNameAuto: '只有输出容器需要名称；存储 / 输入 / 交互容器都用外设名作定义名。',
            machineSlotIn: '输入容器', machineSlotOut: '输出容器', machineSlotSignal: '红石信号',
            machineSlotEmpty: '把外设拖到这里', machineRemove: '移出机器',
            machinePeripheralAdded: '已把 {name} 加到机器 {machine}',
            machinePeripheralRemoved: '已把 {name} 从机器 {machine} 移出',
            machineSlotNeedContainer: '{name} 不是容器外设，不能放进输入 / 输出容器',
            machineSlotNeedSignal: '{name} 不是红石信号外设',
            // 存储容器卡片 / 未分配功能（1.6.3）
    // 1.8.0：物品/流体卡片合并成一张（按角色），并新增输出容器卡片
    storageCard: '存储容器', inputCard: '输入容器', outputCard: '输出容器',
    outputDropHint: '把外设卡片拖到这里：会弹出容器定义弹窗（外设/种类/角色已填好，名称等你填）',
    outputRemove: '移出输出容器（删掉这条定义）',
    outputRole: '输出',
    containerDefineHint: '拖入 {name}：请填写容器名称（角色已设为{role}），保存后生效',
            storageDropHint: '将外设卡片拖入此处以设为存储容器',
            storageRemove: '移出存储（删掉这条定义）',
            storageRemoved: '已把 {name} 移出存储容器',
            inputRole: '输入',
            inputDropHint: '将外设卡片拖入此处以设为输入容器',
            inputRemove: '移出输入容器（定义删除）',
            containerRoleSet: '已把 {name} 设为{kind}（{role}容器）',
            storageNeedKind: '{name} 没有{kind}外设，不能作为该存储容器',
            unassigned: '未分配', unassignedHint: '这个功能未定义：拖拽或者点右侧 + 进行定义',
            createDefinition: '新建定义', clickToEdit: '点击编辑这条定义',
            peripheralsAllAssigned: '所有外设的功能都已分配',
            containerKindLocked: '容器种类由外设能力自动决定，不能手动设置',
            peripheralLocked: '外设名由选中的外设决定，不能手动设置',
            needFreePeripheral: '请在外设卡片上点「+ 容器」新建容器定义',
            diagnoseBtn: '诊断',
            diagnoseRunning: '正在诊断…',
            diagnoseDone: '诊断完成（{mode}，{n} 行）；相同内容也已在CC终端输出（大概是显示不全）',
            sendCountTitle: '发送 {name}', craftCountTitle: '合成 {name}',
            craftAmountHint: '填写想要的产物数量；不足一批按一批算',
            missingPeripheral: '外设缺失', current: '当前',
            running: '进行中', waiting: '等待中', missing: '缺失', idle: '空闲', machineUsed: '并行占用',
            craftOnly: '只合成（不发送）', cancelProcess: '取消流程', processCanceled: '已取消流程',
            clearSendList: '已清空待发送列表', sent: '已提交发送请求', noOutputContainer: '请先定义 output 角色容器',
            processBatch: '本批 ×{n}', processSending: '正在发送 {name} {done}/{target}',
            processExtracting: '正在抽取 {name} {done}/{target}', processWaitMaterials: '等待材料/上游产出',
            processWaitMachine: '等待空闲机器', processWaitSignal: '等待红石信号', processWaitTime: '定时等待中',
            products: '产物',
            connectedTo: '已连接房间 {room}', requestFailed: '请求失败：{error}',
            saved: '已保存',
            autoRenamed: '名称“{old}”已存在，自动命名为“{name}”',
            noData: '暂无数据', itemKind: '物品', fluidKind: '流体', placeholderKind: '占位符', filterKind2: '过滤器',
            pickResource: '从库存选择…',
            pickResourceTitle: '从库存选择', stockCount: '共 {n} 项', stockPicked: '已填入 {name}',
            pickerEmpty: '尚未选择任何项（下拉框添加）', pickerAddHint: '选择要添加的项…',
            moveUp: '上移', moveDown: '下移', pickerRemove: '移除该项',
            addMachineHint: '在该机器类型下新建机器',
            noProcessRunning: '暂无进行中的进程',
            count: '数量', deleteConfirm: '确定要删除「{name}」吗？', editorNew: '新建{kind}', editorEdit: '编辑{kind}',
            progress: '进度', noSend: '待发送列表为空',
            processRemaining: '剩余 {batches} 批 / 约 {products} 个产物',
            processBatchesHint: '该流程要跑几批（每批产出由产物元素的“最多数目”决定）',
            notCraftable: '库存为 0 且无法合成，不能加入待发送',
            craftable: '可合成', noValue: '—',
            workerPanel: '从节点',
            workerNone: '没有 IFMWorker 在线',
            workerWorking: '工作中', workerStale: '失联', workerWaiting: '等待状态',
            workerVersion: '版本 v{version}',
            workerVersionMismatch: '固件版本与主控不一致（Worker v{worker} / 主控 v{server}）；请更新其固件版本。',
            capMove: '搬运', capQuery: '查询',
            workerCurrent: '当前工作：{task}',
            workerWaitingReply: '等待回报（搬运 {moves} · 查询 {queries}）',
            workerLastQuery: '最近查询：{container} {stacks} 组（{ms}ms）',
            workerLastQueryEmpty: '最近查询：{container} 空（{ms}ms）',
            workerScanBlind: '代理扫描无法扫描此容器（此容器是否断开了有线网络？）',
            workerCounters: '搬运 {jobs}（{moved} 个）· 查询 {queries} · 详情 {details} · 在途 {pending}',
            // 并发槽位（1.8.0）：这台 worker 一次能并行跑几条任务、现在跑着几条
            workerLoad: '负载 {load}/{slots}',
            // 本轮第 5/6 项：任务往往 1 个游戏刻就结束，"上报这一刻"的数看不出在干活 —— 显示整秒峰值
            workerLoadPeak: '负载 {load}/{slots}（近 1 秒峰值）',
            workerLoadTitle: '这台 worker 最多能同时跑 {slots} 条任务；进度条 = 近 1 秒的峰值占并发上限的比例',
            // turtle_crafter（预设机器类型）：机器由运行 IFMCrafter 的海龟自动出现，不给「+ 机器」按钮
            machineTypeTurtleCrafter: '海龟合成器',
            machineAutoTurtle: 'IFMCrafter运行中',
            // 本轮第 2 项：「+ 机器」直接按默认参数建一台（不再弹编辑窗口）
            machineAdded: '已创建机器 {name}：把外设拖进它的位置，或点机器卡片改设置',
            // 自动生成的机器是只读的（用户第 5 项）
            machineReadOnly: '只读定义',
            machineReadOnlyHint: '此机器映射至运行中的IFMCrafter的海龟合成器：不可编辑。',
            // 设置：主控本机协程池开关（只在有 worker 在线时才被尊重）
            settingLocalPool: '主控分担任务',
            settingLocalPoolHint: '关闭时，主控在有Worker的情况下自身不再进行查询/物流操作（缺省关）。只有在至少部署了一台IFMWorker时此设置才生效，关闭此开关有助于降低主控压力。',
            // 设置：给网页发服务端日志（日志是 WS 上最大的一块流量）
            settingSendLog: '网页日志输出',
            settingSendLogHint: '启用时，服务端会将日志推送到浏览器控制台，如果不需要调试请勿打开此选项（缺省关）。',
    settingCompactFree: '自动整理空槽阈值',
    settingCompactFreeHint: '存储容器的空槽位如果低于此比例，将启用自动整理以尽可能腾出空槽位。设置为0以禁用自动整理',
            // 卡住被摘掉的任务（1.8.0）：某个容器/外设长时间不响应
            workerStuck: '{n} 个任务超时，已丢弃',
            // 失联的原因说明（用户第 1 项）：卡片不会消失，只是静静地列着"多久没消息了"
            workerSilentFor: '距上次消息 {n}s（失联：暂时不派新活，它一上报就自动恢复）',
            deliveryCancel: '取消此项发送',
            deliveryCancelled: '已取消发送剩余的 {name}（已发送部分不退）',
            workerSummary: '{n} 台在线',
            // 用户第 4 项：从节点总负载（只统计从节点；主控本机的 32 个槽位不计入）
            workerTotalLoad: '总负载 {load}/{slots}（{percent}%）',
            workerTotalLoadTitle: '所有从节点合计：当前并发 / 并发上限（合计 {slots} 个槽位）。主控本机的槽位不计入。',
            // 用户第 6 项：「发送中」栏的"全部删除"（以前只有「待发送」有清空按钮）
            clearDeliveriesConfirm: '清空「发送中」的全部任务？（已经送进目标容器的物品不会退回）',
            deliveriesCleared: '已清空 {n} 条发送中任务',
            deliveriesEmpty: '「发送中」本来就是空的',
            // 用户第 5 项：同一容器 + 同一资源的多次发送会在服务端合并成一条，这里显示"剩余/总共"
            deliveryTotalTitle: '总共（同容器同资源的多次发送会合并到这一条上）',
            // 服务端长时间失联（看门狗的 4 倍时间）后自动回到登录页
            serverLost: '已 {n} 秒未收到服务端数据，服务端可能离线，已返回登录页。',
            compact: '整理',
            compactPlanning: '开始整理：正在计算搬运计划…',
            compactPlanningContainers: '扫描容器 {done}/{total}',
            compactPlanningKinds: '探测种类 {done}/{total}',
            // 自动整理（1.8.0）：没有手动按钮，队列为空时服务端自己算计划并排搬运任务
            compactAuto: '自动整理',
            compactQueue: '已生成 {queued} 条搬运操作 · 队列剩余 {pending} · 累计完成 {done}',
            pendingRequests: '请求中 {n}',
            sendCountHint: '当前待发送 {pending} · 库存 {stock} · 可发送上限 {cap}',
            craftingNow: '合成中…',
            translateOff: '译:关', translateOn: '译:{n}',
            translateLoading: '译:下载中', translateLoadingPercent: '译:{n}%', translateFailed: '译:失败',
            translateTitle: '物品名翻译（英→简中）：首次开启需下载约 37MB 模型',
            translateLoadingRuntime: '正在下载翻译运行时（wasm）…',
            translateLoadingModel: '正在下载翻译模型…',
            translateReady: '翻译已就绪',
            translateCacheCleared: '已清空翻译缓存',
            exprHint: '数量支持四则运算表达式：+ - * / % 与括号，例如 (128+64)/2',
            exprEquals: '= {value}',
            exprInvalid: '表达式无效：{text}（只支持数字、+ - * / % 与括号）',
            capacityItems: '物品容量', capacitySlots: '槽位占用',
            tipRegistry: '注册名', tipKind: '种类', tipStored: '存量', tipSendAmount: '待发送',
            tipRemaining: '剩余',
            tipState: '状态', tipBatch: '本批数量', tipMachine: '机器',
            tipResourceClick: '左键 +1 · Shift+左键 +64 · 右键 -1 · Shift+右键 -64 · 中键 设发送数量 · Shift+中键 设合成数量',
            tipCraftClick: '点右上角 “+”：只合成不发送',
            tipSendClick: '左键 +1 · 右键 -1 · 点右上角 “×” 移除',
            tipTags: '标签',
            searchSyntax: '搜索：关键词（支持英文/中文/拼音） / #标签 / @模组 空格分隔多个条件',
            tipGraphClick: '点击圆点编辑该流程定义',
            tipGraphCraft: '点击节点图标可启动合成',
            tipCrafting: '正在合成', tipCraftTarget: '剩余目标',
            nbtHash: 'NBT 哈希', nbtAny: '留空=无 NBT',
            tagScanning: '标签扫描中 {done}/{total}', tagScanByWorkers: 'worker 代查 {n}', tagsCached: '已缓存 {n} 种物品标签',
            // ===== 用户第 1/2 项：登录页帮助按钮 + 标题行图标化 =====
            help: '帮助', helpHint: '打开 GitHub 仓库（安装说明、更新与问题反馈）',
            statusTags: '已缓存的物品标签种类',
            transferWorkersHint: '从节点搬运的 IFMWorker 台数',
            transferInFlight: '在途任务：{pending}',
            dispatchSteps: '调度器累计推进的步数',
            statusQueue: '{queue}：排队 {depth} · 在飞 {inflight}',
            relayHint: '连不上itty.socket公共中转时可自建中转，或者使用代理/VPN',
            versionLabel: '前端 v{client}',
            versionServer: '服务端 v{server}',
            versionMismatch: '版本不一致：前端 v{client} / 服务端 v{server}。已停止连接，请确保服务端更新至网页同一版本。',
            versionMismatchShort: '版本不一致',
            transferWorkers: '从节点搬运：{n} 台 · 在途 {pending}',
            transferNone: '搬运：本机执行',
            signalChipHint: '将红石中继器外设卡片拖到机器，以运行机器此中继器收发红石信号（同一个中继器可以给多台机器用）',
            signalNameHint: '红石中继器外设无需命名',
            machinePeripheralShared: '{name} 现在被 {machine} 和原机器同时使用',
            transferHint: 'IFMWorker：频道 {channel} · 完成 {done} · 失败 {failed}（明细见「诊断」）',
            transferScanHint: '容器代扫：{cached} 个结果缓存 · {containers} 次容器读取 ·  {localOnly} 次主控扫描 · {blind} 次扫描失败 · 暂停剩余 {paused}s',
            transferHintNone: '无IFMWorker：搬运由本机执行',
            searchClear: '清空搜索',
            peripheralSortTitle: '切换排序：外设名（默认）/ 方块名 / 定义数量',
            sortPeripheralPeripheral: '外设名',
            sortPeripheralBlock: '方块名',
            sortPeripheralDefs: '定义数量',
            sortTitle: '排序', sortCountDesc: '数量降序', sortCountAsc: '数量升序', sortName: '字典序',
            settingsTitle: '设置',
            dispatchMode: '调度 {mode} · {steps} 步',
            // 调度模式（local/remote/mixed/paused）与队列名都本地化（用户第 3 项：状态栏不再混着英文代号）
            dispatchModeLocal: '本机', dispatchModeRemote: '节点', dispatchModeMixed: '混合', dispatchModePaused: '暂停',
            dispatchModeUnknown: '未知',
            dispatchHint: '调度器 {mode} · 累计 {steps} 步 · 本轮 {last}ms（峰值 {max}ms）· 写盘 {writes} 次。',
            // ===== 调度时间片（1.7.0）：每条任务队列每次轮到自己时最多执行几步 =====
            scheduleTitle: '调度权重（各任务队列轮转占时比重）',
            scheduleHint: '每条任务队列的取值范围是 0.01 ~ 1-0.01n（n = 队列条数），总和100%。每条队列至少占 1% 时间；',
            scheduleZeroWarning: '{queue} 的占时已为最小 0.01：几乎轮不到这条队列',
            scheduleZeroWarningShort: '权重已是最小值 0.01（几乎轮不到）',
            scheduleSliderHint: '取值范围 0.01 ~ 1-0.01n；合值始终为 1',
            scheduleHint2: '调度器采用平滑加权轮转：权重越大，这条队列在每一轮里被执行的比例越高。',
            scheduleQueueProcess: '流程处理',
            scheduleQueueStorageScan: '存储容器扫描',
            scheduleQueueInputScan: '输入容器扫描',
            scheduleQueueInteractionScan: '交互容器扫描（机器交互容器）',
            scheduleQueueOutputScan: '输出容器扫描（机器输出 / 发货目标）',
            scheduleQueueInventoryIn: '库存输入（产物 / 入库）',
            scheduleQueueInventoryOut: '库存输出（送料 / 发货）',
            scheduleQueueCompact: '容器整理',
            // 槽位堆叠上限扫描（1.8.0）：自动整理计划要用的"每个物品一组能装多少"
            scheduleQueueStackScan: '槽位堆叠上限扫描',
            scheduleQueueDetail: '物品详情',
            scheduleQueueManual: '手动操作',
            missingDelete: '删除该外设对应的定义',
            missingDeleted: '已删除定义「{name}」',
            missingDeleteAll: '一键删除',
            missingDeleteAllHint: '把所有外设缺失的定义一次删掉（外设缺失时这些定义都用不了）',
            missingDeleteAllConfirm: '确定删除全部 {n} 条外设缺失的定义吗？（引用它们的流程会被冻结，等同名定义回来再恢复）',
            missingDeletedAll: '已删除全部 {n} 条缺失定义',
            missingDeletedSome: '删除了 {deleted} 条，{failed} 条失败（原因见提示）',
            peripheralSelected: '已选 {n} 张外设卡片',
            peripheralSelectedHint: 'Ctrl+点击卡片 = 加选 / 取消；面板里按住右键拖动 = 框选；拖其中一张到机器 = 一起拖过去（类型不匹配的忽略）；Esc = 取消选择',
            peripheralDragHint: '拖这张卡片（或选中的那一批）到机器位置 / 存储卡片；Ctrl+点击 = 加选',
            machinePeripheralsAdded: '已把 {n} 张外设卡片加入「{machine}」',
            machinePeripheralsSkipped: '忽略 {n} 张（类型不匹配）',
            machinePeripheralsNone: '没有可加入「{machine}」的外设卡片（类型不匹配）',
            containerRoleAdded: '已把 {n} 张外设卡片设为{role}容器',
            containerRoleOneByOne: '输出容器要逐条起名字：本次只处理你拖着的那一张',
            containerPut: '放入', containerTake: '取出', containerQueued: '已加入手动操作队列（{n}）',
            containerTool: '容器管理：查看内容物 / 手动放入取出',
            containerManage: '容器管理',
            containerMoveTitle: '手动搬运', containerContents: '当前内容物', resourceLabel: '资源', refresh: '刷新',
            containerEmpty: '容器是空的',
            containerPriority: '存储优先级',
            containerPriorityHint: '越大越先存入、越小越先取出（可负数，缺省 0）',
            processElementPrefix: '{side} {index} · {kind}',
            processNeedMachineType: '请先选择机器类型',
            processUnknownMachineType: '机器类型「{name}」不存在',
            processNoMachineTypes: '还没有机器类型：先创建机器类型与机器，再添加流程',
            processNoMachineOfType: '机器类型「{name}」下没有机器，流程无法运行',
            processMissingResource: '缺少资源名称',
            processUnknownFilter: '过滤器「{name}」不存在',
            processBadCount: '输入数目必须大于 0',
            processBadMax: '“最多数目”必须大于 0',
            processMinOverMax: '“最少数目”不能大于“最多数目”',
            processBadPlaceholder: '占位符需要填写名称与关联物品',
            processBadSignalIndex: '必须指定机器红石信号序号（从 1 开始）',
            processSignalIndexTooBig: '机器红石信号序号超出该机器类型（最多 {n} 条）',
            processNoSignals: '该机器类型下的机器都没有配置红石信号（signals），红石元素无法生效',
            processBadSeconds: '等待时长不能为负',
            processContainerIndexTooBig: '容器序号超出机器输入容器数量（最多 {n}）',
            containerSlots: '槽位 {used}/{total}',
            slotNumber: '槽位 #{n}',
            containerEmptySlot: '空槽位',
            containerUnusable: '容器当前不可用：{reason}',
            containerMoved: '已搬运 {n}',
            containerTakeHint: '点条目右侧的「取」立即取出这一堆；也可以填好资源名与数量后点「取出 / 放入」',
            containerToolUnsaved: '保存这个容器定义后，才能查看内容物与手动搬运',
            wsError: '无法连接中转 {relay}：请检查地址、网络，或改用自建中转',
            wsNoServer: '中继已连接，但房间 {room} 收不到服务端数据：请确认 IFMMaster.lua 仍在运行（Ctrl+T 关掉后需要重新启动）。',
            wsStalled: '已 15 秒没收到服务端数据（服务端可能已关停），正在重新连接…',
            requestTimeout: '请求 {action} 超时（服务端 30 秒无响应）：已自动请求同步，详见日志。',
            wsClosed: '连接已关闭（code={code} {reason}）'
        },
        en: {
            loginHint: 'Enter the same room name as the server.',
            connect: 'Connect', disconnect: 'Disconnect', connecting: 'Connecting…', connected: 'Connected', disconnected: 'Disconnected',
            resources: 'Resources',
            search: 'Search', sendList: 'To send',
            send: 'Send', processes: 'Processes', addProcess: 'Add process',
            deliveries: 'Sending',
            peripherals: 'Peripherals & definitions', container: 'Container', signal: 'Signal',
            peripheralNameHint: 'peripheral name (this is the name used by container definitions, the container tool and diagnose)',
            machines: 'Machines', machineType: 'Machine type', machine: 'Machine', filter: 'Filter',
            graph: 'Process dependency graph', noProcess: 'No process defined',
            save: 'Save', cancel: 'Cancel', ok: 'OK', delete: 'Delete', add: 'Add',
            name: 'Name', peripheral: 'Peripheral', role: 'Role', rules: 'Rules', type: 'Type',
            machineTypeField: 'Machine type', itemInputs: 'Item inputs', fluidInputs: 'Fluid inputs',
            signalsField: 'Signals', itemOutputs: 'Item outputs', fluidOutputs: 'Fluid outputs',
            parallel: 'Parallel signals', maxMultiplier: 'Max multiplier', inputs: 'Inputs', outputs: 'Outputs',
            copyProcessFrom: 'Copy settings from', copyProcessApply: 'Copy',
            copyProcessHint: 'Only processes of the same machine type; abstract processes (containing an "abstract" operation) are listed first and are only meant to be copied from',
            copyProcessDone: 'Copied the inputs/outputs of "{name}"', copyProcessNothing: 'Pick a process in the dropdown first',
            copyProcessOtherType: 'Only processes of the same machine type can be copied', copyProcessOnlyOne: 'No other process of this machine type yet',
            // User item 3: the "virtual operation" concept is gone - set an item/fluid registry name to "abstract" instead
            abstractProcess: 'Abstract', abstractOp: 'Abstract operation',
            abstractHint: 'Set an item/fluid registry name to "abstract": that entry is an "abstract operation" and points at no real resource. A process containing one is an abstract process - it cannot craft, but it can be saved and copied from',
            clearAbstractOps: 'Clear all abstract operations', clearAbstractOpsHint: 'Remove every item/fluid operation whose registry name is "abstract" from both the inputs and the outputs',
            clearAbstractOpsDone: 'Cleared {n} abstract operation(s)', clearAbstractOpsNone: 'No abstract operation found',
            ignoreNbt: 'Ignore NBT', amount: 'Amount', min: 'Min', max: 'Max', priority: 'Priority',
            containerIndex: 'Container index', slot: 'Slot', seconds: 'Seconds', threshold: 'Threshold', strength: 'Strength',
            op: 'Compare', sides: 'Sides', machineSignalIndex: 'Machine redstone signal index',
            side_top: 'Top', side_bottom: 'Bottom', side_left: 'Left', side_right: 'Right', side_front: 'Front', side_back: 'Back',
            signalHint: 'Machine redstone signal index = index in the machine signals list (starts at 1). Threshold/compare only apply to "wait for redstone signal".',
            placeholder: 'Placeholder', item: 'Item', fluid: 'Fluid', filterKind: 'Filter',
            waitSignal: 'Wait signal', emitSignal: 'Set signal', emitPulse: 'Emit redstone pulse', waitTime: 'Wait time',
            storage: 'Storage', interaction: 'Interaction', output: 'Output',
            containerKind: 'Container kind', itemContainer: 'Item container', fluidContainer: 'Fluid container',
            storageNameAuto: 'Only output containers need a name; storage / input / interaction containers use the peripheral name.',
            machineSlotIn: 'Input containers', machineSlotOut: 'Output containers', machineSlotSignal: 'Redstone signals',
            machineSlotEmpty: 'Drag a peripheral here', machineRemove: 'Remove from machine',
            machinePeripheralAdded: 'Added {name} to machine {machine}',
            machinePeripheralRemoved: 'Removed {name} from machine {machine}',
            machineSlotNeedContainer: '{name} is not a container peripheral (input / output containers only)',
            machineSlotNeedSignal: '{name} is not a redstone relay',
    // 1.8.0: item/fluid cards merged into one card per role, plus a new output container card
    storageCard: 'Storage containers', inputCard: 'Input containers', outputCard: 'Output containers',
    outputDropHint: 'Drag a peripheral card here: the container editor opens with peripheral/kind/role prefilled - just type a name',
    outputRemove: 'Remove from output containers (deletes this definition)',
    outputRole: 'Output',
    containerDefineHint: 'Dropped {name}: give the container a name (role is set to {role}) and save',
            storageDropHint: 'Drag a peripheral card here to make it a storage container of this kind',
            storageRemove: 'Remove from storage (deletes this definition)',
            storageRemoved: '{name} removed from storage',
            inputRole: 'input',
            inputDropHint: 'Drag a peripheral card here to make it an input container (things put in are moved into storage automatically)',
            inputRemove: 'Remove from input containers (deletes this definition)',
            containerRoleSet: '{name} is now a{kind} ({role} container)',
            storageNeedKind: '{name} has no {kind} capability, it cannot be that storage container',
            unassigned: 'unassigned',
            unassignedHint: 'This capability has no definition yet: drag it to a storage card or a machine slot, or use + on the right',
            createDefinition: 'Create definition', clickToEdit: 'Click to edit this definition',
            peripheralsAllAssigned: 'Every peripheral capability is assigned',
            containerKindLocked: 'The container kind is derived from the peripheral, it cannot be set manually',
            peripheralLocked: 'The peripheral name is derived from the selected peripheral, it cannot be set manually',
            needFreePeripheral: 'Create a container from a peripheral card ("+ Container")',
            diagnoseBtn: 'Diagnose',
            diagnoseRunning: 'Running diagnose…',
            diagnoseDone: 'Diagnose finished ({mode}, {n} lines); also printed to the console and the CC terminal',
            sendCountTitle: 'Send {name}', craftCountTitle: 'Craft {name}',
            craftAmountHint: 'Amount of the product you want; a partial batch counts as one batch (2 per batch → asking 3 runs 2 batches)',
            missingPeripheral: 'Missing peripheral', current: 'Current',
            running: 'Running', waiting: 'Waiting', missing: 'Missing', idle: 'Idle', machineUsed: 'Parallel usage',
            craftOnly: 'Craft only (no send)', cancelProcess: 'Cancel process', processCanceled: 'Process canceled',
            clearSendList: 'Send list cleared', sent: 'Send request submitted', noOutputContainer: 'Define an output container first',
            processBatch: 'batch ×{n}', processSending: 'Sending {name} {done}/{target}',
            processExtracting: 'Extracting {name} {done}/{target}', processWaitMaterials: 'Waiting for materials/upstream',
            processWaitMachine: 'Waiting for an idle machine', processWaitSignal: 'Waiting for redstone signal',
            processWaitTime: 'Timed wait', products: 'Products',
            connectedTo: 'Connected to {room}', requestFailed: 'Request failed: {error}',
            saved: 'Saved',
            autoRenamed: 'Name "{old}" already exists, using "{name}"',
            noData: 'No data', itemKind: 'Item', fluidKind: 'Fluid', placeholderKind: 'Placeholder', filterKind2: 'Filter',
            pickResource: 'Pick from stock…',
            pickResourceTitle: 'Pick from stock', stockCount: '{n} entries', stockPicked: 'Filled in {name}',
            pickerEmpty: 'Nothing selected yet (use the dropdown below)', pickerAddHint: 'Select an entry to add…',
            moveUp: 'Move up', moveDown: 'Move down', pickerRemove: 'Remove this entry',
            addMachineHint: 'Add a machine of this type',
            noProcessRunning: 'No active processes',
            count: 'Count', deleteConfirm: 'Delete "{name}"?', editorNew: 'New {kind}', editorEdit: 'Edit {kind}',
            progress: 'Progress', noSend: 'Send list is empty',
            processRemaining: 'Left: {batches} batch(es) / ~{products} items',
            processBatchesHint: 'How many batches to run (each batch yields the "max" amount of the output elements)',
            notCraftable: 'No stock and not craftable, cannot queue it',
            workerPanel: 'Workers',
            workerNone: 'No IFMWorker online',
            workerWorking: 'Busy', workerStale: 'Offline', workerWaiting: 'Waiting for state',
            workerVersion: 'v{version}',
            workerVersionMismatch: 'Version mismatch (worker v{worker} vs server v{server}): moves/queries will not be sent to it - copy the same build to that computer',
            capMove: 'move', capQuery: 'query',
            workerCurrent: 'now: {task}',
            workerWaitingReply: 'waiting for a reply (moves {moves} · queries {queries})',
            workerLastQuery: 'last query: {container} {stacks} stack(s) ({ms}ms)',
            workerLastQueryEmpty: 'last query: {container} empty ({ms}ms)',
            workerScanBlind: 'delegated scan sees no containers (last query scanned 0 containers: not on the master\'s wired network?)',
            workerCounters: '{jobs} move(s) / {moved} item(s) · {queries} query(ies) · {details} item detail(s) · in flight {pending}',
            // Parallel slots (1.8.0): how many tasks this worker can run at once / runs now
            workerLoad: 'parallel {load}/{slots}',
            // Tasks usually live one game tick, so an instantaneous number always reads 0 - show the peak
            workerLoadPeak: 'parallel {load}/{slots} (peak in the last second)',
            workerLoadTitle: 'This worker can run up to {slots} tasks at once; the bar is the last-second peak share',
            machineTypeTurtleCrafter: 'Turtle crafter',
            machineAutoTurtle: 'Machines appear automatically: any turtle running IFMCrafter shows up here',
            machineAdded: 'Machine {name} created - drag peripherals into its slots, or click the machine card to change its settings',
            machineReadOnly: 'auto',
            machineReadOnlyHint: 'This machine is generated from a turtle running IFMCrafter: it cannot be edited, deleted, or given redstone signal cards.',
            settingLocalPool: 'Master does work itself',
            settingLocalPoolHint: 'Off (default): the master stops doing moves/queries itself and only uses workers. Honoured only while at least one IFMWorker is online - with none online the master keeps working.',
            settingSendLog: 'Send logs to the browser',
            settingSendLogHint: 'Off (default): the server stops pushing its log lines to the browser console (they are still printed on the server terminal) - this cuts most of the WebSocket traffic.',
    settingCompactFree: 'Auto compact free-slot threshold',
    settingCompactFreeHint: 'Storage compaction only runs while the free-slot share of the storage containers is below this number (0.3 = below 30% free; 1 = always; 0 = never)',
            // Stuck tasks dropped (1.8.0): a container/peripheral stopped answering
            workerStuck: '{n} task(s) dropped after getting stuck (a container/peripheral is not answering, moves keep timing out)',
            // Why it is offline (user item 1): the card stays, it just reports how long there has been no message
            workerSilentFor: 'no message for {n}s (stale: no new jobs for now, recovers by itself once it reports again)',
            deliveryCancel: 'Cancel this delivery',
            deliveryCancelled: 'Delivery of {name} cancelled (items already put into the target stay there)',
            workerSummary: '{n} online',
            // User item 4: total load across the workers (the master machine's own 32 slots are excluded)
            workerTotalLoad: 'total load {load}/{slots} ({percent}%)',
            workerTotalLoadTitle: 'All workers combined: running / capacity ({slots} slots in total). The master machine\'s own slots are not counted.',
            // User item 6: clear every delivery from the "Sending" column
            clearDeliveriesConfirm: 'Clear every delivery in "Sending"? (items already put into the target container stay there)',
            deliveriesCleared: 'Cleared {n} delivery(ies)',
            deliveriesEmpty: '"Sending" is already empty',
            // User item 5: repeated sends of the same resource to the same container are merged, so show "left/total"
            deliveryTotalTitle: 'Total (repeated sends of the same resource to the same container are merged into this entry)',
            serverLost: 'No server data for {n} seconds - back to the login page (the server may be offline)',
            craftable: 'Craftable', noValue: '—',
            nbtHash: 'NBT hash', nbtAny: 'empty = no NBT',
            tagScanning: 'Scanning tags {done}/{total}', tagScanByWorkers: '{n} read by workers', tagsCached: 'Cached tags for {n} item types',
            // ===== Issue 1/2: login help button + icon-only status line =====
            help: 'Help', helpHint: 'Open the GitHub repository (install guide, updates, issues)',
            statusTags: 'Item tag types cached',
            transferWorkersHint: 'IFMWorker nodes doing the moving',
            transferInFlight: 'Tasks in flight: {pending}',
            dispatchSteps: 'Scheduler steps taken so far',
            statusQueue: '{queue}: {depth} queued · {inflight} in flight',
            relayHint: 'If the public relay is unreachable, self-host a broadcast relay and put its url above',
            versionLabel: 'frontend v{client}',
            versionServer: 'server v{server}',
            versionMismatch: 'Version mismatch: frontend v{client} / server v{server}. The connection has been stopped; update the server (backend/IFMMaster.lua) and the page (frontend/) to the same version and retry.',
            versionMismatchShort: 'Version mismatch',
            transferWorkers: 'worker moves: {n} worker(s) · {pending} in flight',
            transferNone: 'moves: run on the server',
            signalChipHint: 'Drag onto a machine redstone signal slot to let that machine use this relay (one relay can serve several machines)',
            signalNameHint: 'Redstone signals need no name: the name is the relay peripheral, and one relay can serve several machines',
            machinePeripheralShared: '{name} is now also used by {machine} (the original machine keeps it)',
            transferHint: 'IFMWorker: channel {channel} · done {done} · failed {failed} (see Diagnose)',
            transferScanHint: 'container scan: cached {cached} · delegated {containers} container(s) · local fallback {localOnly} · worker saw nothing {blind} · pause left {paused}s',
            transferHintNone: 'No IFMWorker: IFM moves items locally',
            searchClear: 'Clear search',
            peripheralSortTitle: 'Sort: peripheral name (default) / block name / definition count',
            sortPeripheralPeripheral: 'Peripheral',
            sortPeripheralBlock: 'Block',
            sortPeripheralDefs: 'Defs',
            sortTitle: 'Sort', sortCountDesc: 'Count (desc)', sortCountAsc: 'Count (asc)', sortName: 'Name',
            settingsTitle: 'Settings',
    dispatchMode: 'scheduler {mode} · {steps} steps',
    dispatchModeLocal: 'local', dispatchModeRemote: 'remote(s)', dispatchModeMixed: 'mixed',
    dispatchModePaused: 'paused', dispatchModeUnknown: 'unknown',
    dispatchHint: 'Scheduler {mode} · {steps} steps total · {last}ms this run (peak {max}ms) · {writes} disk writes. mode: local = no idle worker (the master runs it in parallel); remote = an idle worker is available (queues are dispatched to workers first); mixed = every worker slot is full (the master runs queues from its own coroutine pool); paused = no worker slot and no local slot left (queues are not advanced). depth = queue depth, inflight = handed out, slice = weight (how many *different* tasks a queue may serve per round), dropped = discarded tasks; one task runs at most once per tick',
    // ===== Scheduler time slices (1.7.0): steps per queue turn =====
    scheduleTitle: 'Scheduler weights (share of each round per queue; all queues add up to 1)',
    scheduleHint: 'Every queue takes a decimal between 0.01 and 1-0.01n (n = number of queues) and they all add up to 1 (the server normalises on save). Dragging one slider rescales the others proportionally - pulling one from 0.2 to 0.5 shrinks the rest so the total stays 1. **0 is not allowed**: every queue always keeps at least 0.01 (otherwise dragging every slider to 0 would make normalisation impossible); a row already at the minimum turns red with a warning icon.',
    scheduleZeroWarning: '{queue} is already at the minimum weight 0.01: this queue hardly ever gets a turn (the others fill the round)',
    scheduleZeroWarningShort: 'At the minimum weight 0.01 (hardly ever runs)',
    scheduleSliderHint: 'Range 0.01 ~ 1-0.01n; dragging rescales the other queues so the total stays 1',
    scheduleHint2: 'The scheduler is a smooth weighted round robin: a larger weight means a larger share of every round, and it is never run in one long burst. One task runs at most once per tick (a container scan already sees everything a single list() returns; a process only advances 20 times per second), so the weight really decides how many *different* tasks a queue may serve per round. The total is limited by workers + the master coroutine pool: only when both are out of slots does the scheduler pause.',
    scheduleQueueProcess: 'Process handling (one step = one process advances once)',
    scheduleQueueStorageScan: 'Storage container scan',
    scheduleQueueInputScan: 'Input container scan',
    scheduleQueueInteractionScan: 'Interaction container scan (machine containers)',
    scheduleQueueOutputScan: 'Output container scan (machine outputs / delivery targets)',
    scheduleQueueInventoryIn: 'Inventory in (feeding machines / input containers into storage)',
    scheduleQueueInventoryOut: 'Inventory out (product extraction / deliveries)',
    scheduleQueueCompact: 'Container compaction',
    // Slot stack-limit scan (1.8.0): what the automatic compaction planner needs
    scheduleQueueStackScan: 'Slot stack-limit scan (input for auto compaction)',
    scheduleQueueDetail: 'Item details',
    scheduleQueueManual: 'Manual operations (interactive container moves)',
            missingDelete: 'Delete the definition behind this missing peripheral',
            missingDeleted: 'Deleted definition "{name}"',
            missingDeleteAll: 'Delete all',
            missingDeleteAllHint: 'Delete every definition whose peripheral is missing (they cannot be used while the peripheral is gone)',
            missingDeleteAllConfirm: 'Delete all {n} definitions whose peripheral is missing? (processes referencing them are frozen until a definition with the same name comes back)',
            missingDeletedAll: 'Deleted all {n} missing definitions',
            missingDeletedSome: 'Deleted {deleted}, failed {failed} (see the toasts)',
            peripheralSelected: '{n} peripheral card(s) selected',
            peripheralSelectedHint: 'Ctrl+click a card = add/remove; hold the right button and drag inside the panel = rubber-band select; drag one of them onto a machine = drag them all (mismatched kinds are ignored); Esc = clear',
            peripheralDragHint: 'Drag this card (or the whole selection) onto a machine slot / container card; Ctrl+click = add to the selection',
            machinePeripheralsAdded: 'Added {n} peripheral card(s) to "{machine}"',
            machinePeripheralsSkipped: '{n} ignored (wrong kind)',
            machinePeripheralsNone: 'No peripheral card can be added to "{machine}" (wrong kind)',
            containerRoleAdded: 'Set {n} peripheral card(s) as {role} container(s)',
            containerRoleOneByOne: 'Output containers are named one by one: only the card you dragged is handled',
            containerPut: 'Put in', containerTake: 'Take out', containerQueued: 'Queued as a manual operation ({n})',
            containerTool: 'Container tool: view contents / move items in and out manually',
            containerManage: 'Container tool',
            containerMoveTitle: 'Manual transfer', containerContents: 'Contents', resourceLabel: 'Resource', refresh: 'Refresh',
            containerEmpty: 'The container is empty',
            containerPriority: 'Storage priority',
            containerPriorityHint: 'Higher = filled first, lower = emptied first (negatives allowed, 0 by default)',
            processElementPrefix: '{side} {index} · {kind}',
            processNeedMachineType: 'Choose a machine type first',
            processUnknownMachineType: 'Machine type "{name}" does not exist',
            processNoMachineTypes: 'No machine type defined yet: create a machine type and a machine before adding a process',
            processNoMachineOfType: 'No machine uses machine type "{name}": add one to this type first',
            processMissingResource: 'missing the resource name',
            processUnknownFilter: 'filter "{name}" does not exist',
            processBadCount: 'input amount must be greater than 0',
            processBadMax: '"max" must be greater than 0',
            processMinOverMax: '"min" must not be greater than "max"',
            processBadPlaceholder: 'a placeholder needs both a name and an item',
            processBadSignalIndex: 'machine redstone signal index is required (starts at 1)',
            processSignalIndexTooBig: 'signal index exceeds this machine type (max {n})',
            processNoSignals: 'No machine of this type defines redstone signals, so signal elements cannot work',
            processBadSeconds: 'wait time cannot be negative',
            processContainerIndexTooBig: 'container index exceeds the machine input containers (max {n})',
            containerSlots: 'Slots {used}/{total}',
            slotNumber: 'Slot #{n}',
            containerEmptySlot: 'Empty slot',
            containerUnusable: 'Container is not usable right now: {reason}',
            containerMoved: 'Moved {n}',
            containerTakeHint: 'Click "Take out" on a row to move that whole stack, or fill the resource and amount and use Take out / Put in',
            containerToolUnsaved: 'Save this container definition first to view its contents and move items by hand',
            wsError: 'Cannot connect to relay {relay}: check address/network or self-host a relay',
            wsNoServer: 'The relay is connected but no data comes from room {room}: make sure IFMMaster.lua is still running (Ctrl+T stops it).',
            wsStalled: 'No server data for 15 seconds (the server may be offline), reconnecting…',
            requestTimeout: 'Request {action} timed out (no response within 30s); data was re-synced once. See the CC terminal and the [IFM] console lines.',
            wsClosed: 'Connection closed (code={code} {reason})',
            compact: 'Compact',
            compactPlanning: 'Compacting: planning the moves…',
            compactPlanningContainers: 'scanning containers {done}/{total}',
            compactPlanningKinds: 'probing kinds {done}/{total}',
            // Automatic compaction (1.8.0): no manual button; the server plans and queues moves whenever the queue is empty
            compactAuto: 'Auto compaction',
            compactQueue: '{queued} move task(s) generated · {pending} left in the queue · {done} finished so far',
            pendingRequests: 'pending {n}',
            sendCountHint: 'Pending {pending} · stored {stock} · max {cap}',
            craftingNow: 'Crafting…',
            translateOff: 'Tr:off', translateOn: 'Tr:{n}',
            translateLoading: 'Tr:download', translateLoadingPercent: 'Tr:{n}%', translateFailed: 'Tr:failed',
            translateTitle: 'Item name translation (en→zh-Hans): first enable downloads ~37MB of model files; Shift+click clears the cache',
            translateLoadingRuntime: 'Downloading the translation runtime (wasm)...',
            translateLoadingModel: 'Downloading the translation model...',
            translateReady: 'Translation ready',
            translateCacheCleared: 'Translation cache cleared',
            exprHint: 'Amounts accept arithmetic: + - * / % and parentheses, e.g. 2*64+32 or (128+64)/2',
            exprEquals: '= {value}',
            exprInvalid: 'Invalid expression: {text} (only numbers, + - * / % and parentheses)',
            capacityItems: 'Item capacity', capacitySlots: 'Slot usage',
            tipRegistry: 'Registry', tipKind: 'Kind', tipStored: 'Stored', tipSendAmount: 'To send',
            tipRemaining: 'Left',
            tipState: 'State', tipBatch: 'Batch size', tipMachine: 'Machine',
            tipResourceClick: 'Left click +1 · Shift+Left +64 · Right click -1 · Shift+Right -64 · Middle click set send count · Shift+Middle set craft count',
            tipCraftClick: 'Click "+" at the top right: craft only (no send)',
            tipSendClick: 'Left click +1 · Right click -1 · click "×" to remove',
            tipTags: 'Tags',
            searchSyntax: 'Search: keyword (English / Chinese / pinyin, e.g. gzt or gongzuotai) / #tag / @mod (space separates conditions, all must match)',
            tipGraphClick: 'Click the dot to edit this process',
            tipGraphCraft: 'Click the node icon to enter a craft amount (craft only, no send)',
            tipCrafting: 'Crafting', tipCraftTarget: 'Left to craft'
        }
    };

    // ===================== 通用工具 =====================
    function el(id) {
        return document.getElementById(id);
    }

    function escapeHtml(text) {
        return String(text === null || text === undefined ? '' : text)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    function keyOf(category, item) {
        if (category === 'resources' || category === 'peripherals' || category === 'missing') {
            return (item.kind || '') + ':' + (item.name || '');
        }
        if (category === 'deliveries') {
            return String(item.id);
        }
        if (category === 'workers') {
            return String(item.id);
        }
        if (category === 'containers') {
            return containerKeyOf(item);
        }
        return item.name;
    }

    // 容器的内部键：kind:名称 —— 物品容器与流体容器允许同名，所以键里要带种类
    function containerKeyOf(item) {
        const kind = item && item.kind === 'fluid' ? 'fluid' : 'item';
        return kind + ':' + ((item && item.name) || '');
    }

    function containerByKey(key) {
        if (!key || !stores.containers) return null;
        return stores.containers.get(key) || null;
    }

    // 按（纯）名称查容器定义：给了 kind 就按种类查，否则先物品后流体
    function containerByName(name, kind) {
        if (!name) return null;
        const plain = String(name).replace(/^(item|fluid):/, '');
        if (kind) return containerByKey(containerKeyOf({ kind: kind, name: plain }));
        return containerByKey(containerKeyOf({ kind: 'item', name: plain }))
            || containerByKey(containerKeyOf({ kind: 'fluid', name: plain }));
    }

    function resourceKey(kind, name) {
        return kind + ':' + name;
    }

    function splitKey(key) {
        const index = key.indexOf(':');
        return [key.slice(0, index), key.slice(index + 1)];
    }

    // ===================== ASCII 传输层（只在浏览器端转码） =====================
    // CC:Tweaked 不支持非 ASCII 字符：网页里输入的中文/emoji 在发送前转成 `\uXXXX` 字面文本，
    // 服务端只原样收发与存储（它就是普通 ASCII 字符串，服务端不做任何编码/解码）；
    // 服务端回传的名称字段再在收到后还原成真正的字符供界面显示/编辑。
    function hex4(code) {
        let text = code.toString(16).toUpperCase();
        while (text.length < 4) text = '0' + text;
        return '\\u' + text;
    }

    // 编码：反斜杠 -> \u005C（避免与转义序列冲突），控制字符与非 ASCII -> \uXXXX
    function escapeUnicodeForServer(text) {
        const value = String(text === null || text === undefined ? '' : text);
        let out = '';
        for (let i = 0; i < value.length; i += 1) {
            const code = value.charCodeAt(i);
            if (code === 0x5C) {
                out += '\\u005C';
            } else if (code >= 0x20 && code <= 0x7E) {
                out += value.charAt(i);
            } else {
                out += hex4(code);   // 控制字符、非 ASCII，以及代理对的两半
            }
        }
        return out;
    }

    // 解码：把 \uXXXX（含代理对）还原成真正的字符，其余原样保留
    function unescapeAsciiText(text) {
        const value = String(text === null || text === undefined ? '' : text);
        let out = '';
        let i = 0;
        while (i < value.length) {
            if (value.charAt(i) === '\\' && value.charAt(i + 1) === 'u') {
                const hex = value.substr(i + 2, 4);
                if (/^[0-9A-Fa-f]{4}$/.test(hex)) {
                    out += String.fromCharCode(parseInt(hex, 16));
                    i += 6;
                    continue;
                }
            }
            out += value.charAt(i);
            i += 1;
        }
        return out;
    }

    // 需要转码的字段路径：只处理“名称/文本”字段（定义名、对定义的引用、外设名、服务端提示），
    // 不做整包转换 —— 物品/流体注册名、NBT 哈希、枚举值、数字、action/id 等一律原样传输。
    // 路径写法：`a`、`a.b`、`a[]`（数组每个元素）、`a[].b`（数组元素的字段）。
    // 转码只在浏览器端进行：服务端不认识这些转义，只原样收发与存储；
    // 新增带文本的定义字段时，记得同时补上 OUTBOUND_TEXT_PATHS 与 CATEGORY_TEXT_PATHS。
    const OUTBOUND_TEXT_PATHS = {
        set_container: ['name', 'data.peripheral'],
        set_signal: ['name', 'data.peripheral'],
        set_machine_type: ['name'],
        set_filter: ['name', 'data.rules[].id'],
        set_machine: ['name', 'data.type', 'data.itemInputs[]', 'data.fluidInputs[]',
            'data.itemOutputs[]', 'data.fluidOutputs[]', 'data.signals[]'],
        set_process: ['name', 'data.machineType', 'data.inputs[].id', 'data.inputs[].name',
            'data.outputs[].id', 'data.outputs[].name'],
        delete_container: ['name'], delete_signal: ['name'], delete_filter: ['name'],
        delete_machine_type: ['name'], delete_machine: ['name'], delete_process: ['name'],
        start_process: ['name'], set_process_count: ['name'], cancel_process: ['name'],
        craft_resource: ['name', 'process'],
        send_items: ['container', 'items[].name'],
        delete_deliveries: [],
    };

    // 各类别（服务端推送）里需要还原的字段路径
    const CATEGORY_TEXT_PATHS = {
        containers: ['name', 'peripheral'],
        signals: ['name', 'peripheral'],
        machineTypes: ['name'],
        filters: ['name', 'rules[].id'],
        machines: ['name', 'type', 'itemInputs[]', 'fluidInputs[]', 'itemOutputs[]', 'fluidOutputs[]', 'signals[]'],
        processes: ['name', 'machineType', 'inputs[].id', 'inputs[].name', 'outputs[].id', 'outputs[].name'],
        peripherals: ['name', 'containers[].name', 'signals[].name',
            'containers[].peripheral', 'signals[].peripheral'],
        missing: ['name', 'peripheral'],
        resources: ['name', 'samples[].name'],
        runtime: ['name', 'machine', 'progress[].id', 'lastError', 'current.id', 'current.name'],
        deliveries: ['name', 'container', 'processName', 'lastError'],
    };

    // 服务端响应（result）里的名称与提示信息（提示里可能嵌入被转义的定义名）
    const RESPONSE_TEXT_PATHS = [
        'error', 'result.error', 'result.name', 'result.process',
        'result.info.process', 'result.info.name', 'result.info.canceled',
        'result.results[].name', 'result.results[].error', 'result.lines[]',
    ];

    function applyTextPaths(target, paths, fn) {
        if (!target || typeof target !== 'object' || !paths) return target;
        paths.forEach(function (path) { walkTextPath(target, path.split('.'), 0, fn); });
        return target;
    }

    function walkTextPath(node, parts, index, fn) {
        if (!node || typeof node !== 'object') return;
        const part = parts[index];
        const last = index === parts.length - 1;
        const isArray = part.slice(-2) === '[]';
        const key = isArray ? part.slice(0, -2) : part;
        const value = node[key];
        if (value === undefined || value === null) return;
        if (isArray) {
            if (!Array.isArray(value)) return;
            if (last) {
                for (let i = 0; i < value.length; i += 1) {
                    if (typeof value[i] === 'string') value[i] = fn(value[i]);
                }
                return;
            }
            value.forEach(function (item) { walkTextPath(item, parts, index + 1, fn); });
            return;
        }
        if (last) {
            if (typeof value === 'string') node[key] = fn(value);
            return;
        }
        walkTextPath(value, parts, index + 1, fn);
    }

    // 发送前：只转义该 action 涉及的名称字段
    function escapePayloadForServer(payload) {
        if (!payload || typeof payload !== 'object') return payload;
        applyTextPaths(payload, OUTBOUND_TEXT_PATHS[payload.action], escapeUnicodeForServer);
        return payload;
    }

    // 收到后：只还原名称字段（类别推送按类别取路径，其余按响应路径）
    function decodeFrameFromServer(data) {
        if (!data || typeof data !== 'object') return data;
        if (data.action === 'incremental_update' && data.changes && typeof data.changes === 'object') {
            Object.keys(data.changes).forEach(function (category) {
                const list = data.changes[category];
                if (!Array.isArray(list)) return;
                const paths = CATEGORY_TEXT_PATHS[category];
                if (!paths) return;
                list.forEach(function (item) { applyTextPaths(item, paths, unescapeAsciiText); });
            });
            return data;
        }
        applyTextPaths(data, RESPONSE_TEXT_PATHS, unescapeAsciiText);
        return data;
    }

    // ===================== 服务端数据规范化 =====================
    // CC:T 的 textutils.serializeJSON 无法区分“空数组”和“空对象”：服务端 Lua 里的空数组
    // 序列化成 JSON 后是 {}，前端直接 .map / .forEach / .length 会抛
    // “(intermediate value).map is not a function”。因此收数据时把“本应是数组”的字段修正成真数组。
    function asArray(value) {
        return Array.isArray(value) ? value : [];
    }

    // 各类别里“本应是数组”的字段
    const ARRAY_FIELDS = {
        filters: ['rules'],
        machines: ['itemInputs', 'fluidInputs', 'signals', 'itemOutputs', 'fluidOutputs'],
        processes: ['inputs', 'outputs'],
        peripherals: ['containers', 'signals'],
        resources: ['samples', 'tags'],
        runtime: ['progress'],
    };

    // 数组元素内部还需要规范化的数组字段（流程输入/输出元素的 sides）
    const NESTED_ARRAY_FIELDS = {
        processes: { inputs: ['sides'], outputs: ['sides'] },
    };

    function normalizeItemArrays(category, item) {
        if (!item || typeof item !== 'object') return item;
        asArray(ARRAY_FIELDS[category]).forEach(function (field) {
            if (item[field] !== undefined) item[field] = asArray(item[field]);
        });
        const nested = NESTED_ARRAY_FIELDS[category];
        if (nested) {
            Object.keys(nested).forEach(function (field) {
                if (!Array.isArray(item[field])) {
                    item[field] = [];
                    return;
                }
                item[field].forEach(function (element) {
                    if (!element || typeof element !== 'object') return;
                    nested[field].forEach(function (inner) {
                        if (element[inner] !== undefined) element[inner] = asArray(element[inner]);
                    });
                });
            });
        }
        return item;
    }

    // 元素暂时缺失时也不抛错：DOM 结构与脚本不同步（例如浏览器缓存了旧页面）时界面不会崩溃
    function setText(id, value) {
        const node = el(id);
        if (node) node.textContent = value;
        return node;
    }

    function setDisplay(id, value) {
        const node = el(id);
        if (node) node.style.display = value;
        return node;
    }

    // 提示框容器：正常由 index.html 提供；缺失时按需创建，保证 toast 永不因容器为 null 而报错
    function toastAreaNode() {
        let node = el('toastArea');
        if (!node) {
            node = document.createElement('div');
            node.id = 'toastArea';
            const parent = document.body || document.documentElement;
            if (!parent) return node;
            parent.appendChild(node);
        }
        return node;
    }

    function toast(message, type) {
        const box = document.createElement('div');
        box.className = 'toast-msg ' + (type || 'info');
        box.textContent = message;
        toastAreaNode().appendChild(box);
        setTimeout(function () {
            box.remove();
        }, 4200);
    }

    function setConnectionStatus(kind) {
        const dot = el('statusDot');
        if (dot) {
            dot.className = 'status-dot ' + (kind === 'online' ? 'online' : (kind === 'connecting' ? 'connecting' : ''));
        }
        const text = kind === 'online' ? t('connected') : (kind === 'connecting' ? t('connecting') : t('disconnected'));
        setText('statusText', text);
        // 登录按钮的"连接中"状态跟着连接状态走：连上/失败都会自动恢复
        // （用户第 3 项：按下去立刻有反馈，但按钮不能永远卡在转圈）
        if (kind !== 'connecting' && window.ifmSetConnectBusy) {
            window.ifmSetConnectBusy(false);
        }
    }

    // 只有真的收到服务端帧（带 action 的消息）才算“已连接”：
    // 中继（itty.ws）在服务端下线时依然会接受 WebSocket 连接（onopen 照样触发），
    // 所以不能凭 onopen 就显示“已连接”——否则服务端关掉后页面会一直假装在线。
    function markServerSeen() {
        lastHeartbeatAt = Date.now();
        lastServerDataAt = lastHeartbeatAt;
        everSeenServer = true;
        if (serverSeen) return;
        serverSeen = true;
        // 确认服务端在线后才切到主界面：服务端没在跑时页面会稳定停在登录框
        //（而不是“登录框 ↔ 空主界面”来回闪）
        setDisplay('loginOverlay', 'none');
        setDisplay('app', 'block');
        setConnectionStatus('online');
        toast(t('connectedTo', { room: '****' }), 'success');
    }

    function fmtCount(value) {
        const number = Number(value);
        if (!isFinite(number)) return t('noValue');
        const abs = Math.abs(number);
        if (abs >= 1000000000) return (number / 1000000000).toFixed(2) + 'b';
        if (abs >= 1000000) return (number / 1000000).toFixed(2) + 'm';
        if (abs >= 1000) return (number / 1000).toFixed(2) + 'k';
        return String(Math.round(number));
    }

    function metaOf(kind, name) {
        const meta = metaCache.get(resourceKey(kind, name));
        return (meta && meta !== 'missing') ? meta : null;
    }

    // 这个资源的信息还在接口路上吗？（排队中，或正在批量抓取）
    // 用途：翻译排队时先别翻兜底文本——等真名到了再翻（见 queueTranslateNames）。
    function isMetaPending(kind, name) {
        const key = resourceKey(kind, name);
        if (metaCache.has(key)) return false;
        if (metaQueue.indexOf(key) >= 0) return true;
        return metaActive > 0 && (metaRetryAt.get(key) || 0) <= Date.now();
    }

    function displayName(kind, name) {
        // 三层优先级（任务 8 / 1.6.12）：① icon-exports 本地导出名（中文，若导出文件正常）
        // → ② blocksitems 的 display_name → ③ 注册名去下划线 / Bergamot 翻译
        // icon-exports 的 <lang>.json 里就是这个语言的官方物品名（en.json 就是英文名）：
        // 中英都用它，比 blocksitems 的英文名 / 注册名去下划线都准。
        // 只有“当前语言的元数据文件没加载成功”时它才返回 ''（那时才往后落）。
        // 以前只在中文下用，导致英文界面永远显示注册名去下划线。
        const exported = iconExportName(kind, name);
        if (exported) return exported;
        const english = englishName(kind, name);
        // 开启 Bergamot 名称翻译后优先显示中文（翻译结果由 web/ifm-translate.js 提供）
        const translator = window.IFMTranslate;
        if (translator && translator.isEnabled()) {
            const translated = translator.nameFor(english);
            if (translated) return translated;
        }
        return english;
    }

    // 接口给的（英文）显示名：搜索时中英都能搜到，所以两边都要留着
    function englishName(kind, name) {
        const meta = metaOf(kind, name);
        if (meta && meta.display_name) return meta.display_name;
        const path = String(name || '').split(':').pop();
        return path ? path.replace(/_/g, ' ') : String(name || '');
    }

    // 开了名称翻译时：把要用到的英文名排队交给 Bergamot（翻好后 ifmOnTranslateUpdate 会让界面重画）
    // 优先用 blocksitems 给的 display_name（接口数据比“注册名去下划线”准得多）；
    // 接口数据还在路上（metaActive/metaQueue 里有它）时先不排队 —— 等它到了会再画一次，
    // 那时用真正的显示名翻译，避免先翻一遍“andesite casing”这种兜底文本。
    function queueTranslateNames(list) {
        const translator = window.IFMTranslate;
        if (!translator || !translator.isEnabled() || translator.status() !== 'ready') return;
        const names = [];
        asArray(list).forEach(function (entry) {
            const meta = metaOf(entry.kind, entry.name);
            if (!meta && isMetaPending(entry.kind, entry.name)) return;   // 等接口数据
            names.push(englishName(entry.kind, entry.name));
        });
        if (names.length > 0) translator.queueNames(names);
    }

    // 「译」按钮状态文案：未开启 / 下载 45% / 已开启（已翻译 N 个名字）/ 失败
    function translateMessageText(message) {
        if (!message) return '';
        const pack = I18N[lang] || I18N.zh;
        return pack[message] || message;
    }

    function renderTranslateButton() {
        const node = el('translateLabel');
        const button = el('translateBtn');
        if (!node || !button) return;
        const translator = window.IFMTranslate;
        if (!translator) {
            button.style.display = 'none';
            return;
        }
        if (!translator.isEnabled()) {
            node.textContent = t('translateOff');
            button.title = t('translateTitle');
            return;
        }
        const status = translator.status();
        if (status === 'ready') {
            node.textContent = t('translateOn', { n: fmtCount(translator.translatedCount()) });
            button.title = t('translateTitle');
            return;
        }
        if (status === 'failed') {
            node.textContent = t('translateFailed');
            button.title = translateMessageText(translator.message()) || t('translateTitle');
            return;
        }
        const percent = translator.progressPercent();
        node.textContent = percent ? t('translateLoadingPercent', { n: percent }) : t('translateLoading');
        button.title = translateMessageText(translator.message()) || t('translateTitle');
    }

    // ===================== 版本号 =====================
    // 顶部显示「前端 vX」；服务端版本号来自 status.version（后端 buildStatus 里写入）。
    // 两边不一致时由 ifm-net.js 停止连接，这里只负责显示状态。
    function renderVersionLabel() {
        const label = el('versionLabel');
        if (label) {
            label.textContent = versionMismatch
                ? t('versionMismatchShort')
                : t('versionLabel', { client: IFM_CLIENT_VERSION });
            label.title = t('versionLabel', { client: IFM_CLIENT_VERSION }) +
                (serverVersion ? ' · ' + t('versionServer', { server: serverVersion }) : '');
            label.style.color = versionMismatch ? 'var(--bad)' : '';
        }
        const hint = el('versionHint');
        if (hint) {
            hint.textContent = t('versionLabel', { client: IFM_CLIENT_VERSION }) +
                (serverVersion ? ' · ' + t('versionServer', { server: serverVersion }) : '');
        }
    }

    // ===== 用户第 2 项：标题行只留「图标 + 数字」=====
    // 以前这里是一长串中文明细（"已缓存 334 种物品标签 从节点搬运：7 台 · 在途 0 ..."），
    // 挤在一行里既看不出重点，也没法一眼扫。现在每个数字前放一个图标，含义全部移到悬停提示里
    // （图标与数字都带 title，鼠标停在谁上面都能看到它是什么）。
    function statusStatHtml(glyph, value, hint) {
        return '<i class="fa ' + glyph + ' status-icon"' +
            (hint ? ' title="' + escapeHtml(hint) + '"' : '') + '></i>' +
            '<span class="status-value">' + escapeHtml(value === null || value === undefined ? '' : String(value)) +
            '</span>';
    }

    // IFMWorker 搬运卸载状态（顶部显示）：有 worker 时显示台数与在途任务，否则显示“本机搬运”
    function renderTransferInfo() {
        const node = el('transferInfo');
        if (!node) return;
        const info = status ? status.transfer : null;
        if (info && info.available) {
            const scan = info.scan || {};
            const workers = info.workers || 0;
            const pending = info.pending || 0;
            node.innerHTML = statusStatHtml('fa-truck', workers, t('transferWorkersHint')) +
                statusStatHtml('fa-hourglass-half', pending, t('transferInFlight', { pending: pending })) +
                statusStatHtml('fa-magnifying-glass', scan.cached || 0, t('transferScanHint', {
                    cached: scan.cached || 0,
                    containers: scan.containers || 0,
                    localOnly: scan.localOnly || 0,
                    blind: scan.blind || 0,
                    paused: scan.pauseLeft || 0
                }));
            node.title = t('transferHint', {
                channel: info.channel,
                done: info.done || 0,
                failed: info.failed || 0
            }) + '\n' + t('transferScanHint', {
                cached: scan.cached || 0,
                containers: scan.containers || 0,
                localOnly: scan.localOnly || 0,
                blind: scan.blind || 0,
                paused: scan.pauseLeft || 0
            });
            // 容器代扫无效（worker 看不到容器 / 连续失败被暂停）时标黄：
            // 只藏在 title 里没人会去看，而这两种情况意味着“主控一直在自己读容器”
            node.style.color = ((scan.blind || 0) > 0 || (scan.paused || 0) > 0) ? 'var(--warn)' : '';
            return;
        }
        node.innerHTML = info ? statusStatHtml('fa-desktop', t('transferNone'), t('transferHintNone')) : '';
        node.title = t('transferHintNone');
        node.style.color = '';
    }

    // 调度器信息（1.7.0）：模式 + 各队列深度/在途 + 每轮耗时。
    // 一眼看出：worker 是不是被用满了（mode=remote 且队列为空 = 都在干活；mode=paused = 全忙）。
    // 用户第 3 项：模式名与队列名都要走译文（以前状态栏里混着 remote / storageScan 这种英文代号，
    // 中文界面上看起来像"没本地化的内容"）。译文缺失时才退回原始代号。
    function dispatchI18n(key, fallback) {
        const text = t(key);
        return (text && text !== key) ? text : fallback;
    }

    function dispatchQueueLabel(name) {
        const raw = String(name || '?');
        const key = 'scheduleQueue' + raw.charAt(0).toUpperCase() + raw.slice(1);
        return dispatchI18n(key, raw);
    }

    function dispatchModeLabel(mode) {
        const raw = String(mode || '?');
        const key = 'dispatchMode' + raw.charAt(0).toUpperCase() + raw.slice(1);
        return dispatchI18n(key, dispatchI18n('dispatchModeUnknown', raw));
    }

    // 各队列 / 各调度模式的图标（用户第 2 项：标题行只留图标 + 数字，含义在悬停提示里）。
    function dispatchQueueGlyph(name) {
        if (name === 'process') return 'fa-cogs';
        if (name === 'storageScan') return 'fa-archive';
        if (name === 'inputScan') return 'fa-sign-in';
        if (name === 'interactionScan') return 'fa-cubes';
        if (name === 'outputScan') return 'fa-sign-out';
        if (name === 'inventoryIn') return 'fa-arrow-down';
        if (name === 'inventoryOut') return 'fa-arrow-up';
        if (name === 'compact') return 'fa-compress';
        if (name === 'stackScan') return 'fa-layer-group';
        if (name === 'detail') return 'fa-info-circle';
        if (name === 'manual') return 'fa-hand-pointer';
        return 'fa-list';
    }

    function dispatchModeGlyph(mode) {
        if (mode === 'local') return 'fa-desktop';
        if (mode === 'remote') return 'fa-server';
        if (mode === 'mixed') return 'fa-random';
        if (mode === 'paused') return 'fa-pause';
        return 'fa-question';
    }

    function renderDispatchInfo() {
        const node = el('dispatchInfo');
        if (!node) return;
        const info = status && status.dispatch;
        if (!info) {
            node.innerHTML = '';
            node.title = '';
            return;
        }
        const short = [];
        const detail = [];
        asArray(info.queues).forEach(function (queue) {
            const depth = queue.depth || 0;
            const inflight = queue.inflight || 0;
            if (depth > 0 || inflight > 0) {
                // 一个队列 = 一个图标 + 一个数字（该队列没干完的量：排队 + 在飞）
                short.push(statusStatHtml(dispatchQueueGlyph(queue.name), depth + inflight,
                    t('statusQueue', {
                        queue: dispatchQueueLabel(queue.name),
                        depth: depth,
                        inflight: inflight
                    })));
            }
            detail.push(dispatchQueueLabel(queue.name) + ': depth=' + depth + ' (active=' + (queue.active || 0) +
                ' waiting=' + (queue.waiting || 0) + ') inflight=' + inflight +
                ' weight=' + (queue.slice || 1) + ' served=' + (queue.served || 0) +
                ' dropped=' + (queue.dropped || 0) + ' retried=' + (queue.retried || 0) +
                ' promoted=' + (queue.promoted || 0) +
                ' needs=' + (queue.needs || 'none') + ' policy=' + (queue.policy || 'retry'));
        });
        node.innerHTML = statusStatHtml(dispatchModeGlyph(info.mode), '',
                t('dispatchMode', { mode: dispatchModeLabel(info.mode), steps: fmtCount(info.steps || 0) })) +
            statusStatHtml('fa-forward-step', fmtCount(info.steps || 0), t('dispatchSteps')) +
            short.join('');
        node.title = t('dispatchHint', {
            mode: dispatchModeLabel(info.mode), steps: info.steps || 0,
            last: Math.round((info.lastMs || 0) * 10) / 10,
            max: Math.round((info.maxMs || 0) * 10) / 10,
            writes: info.writes || 0
        }) + (detail.length > 0 ? '\n' + detail.join('\n') : '');
    }

    // 资源类型徽标字形（物品 / 流体 / 过滤器 / 占位符）：资源卡片左上角与机器容器芯片共用    // 资源类型徽标字形（物品 / 流体 / 过滤器 / 占位符）：资源卡片左上角与机器容器芯片共用
    function kindBadgeGlyph(kind) {
        if (kind === 'fluid') return 'fa-tint';
        if (kind === 'filter') return 'fa-filter';
        if (kind === 'placeholder') return 'fa-thumb-tack';
        if (kind === 'signal') return 'fa-bolt';
        return 'fa-cube';
    }

    // 接口返回的相对地址（例如 lookup 的 icon_url = /api/v1/images/<hash>）补全成绝对地址
    function absoluteApiUrl(url) {
        if (!url) return '';
        return url.charAt(0) === '/' ? API_ORIGIN + url : url;
    }

    // 图标地址：优先用 lookup 返回的 icon_url（/api/v1/images/<hash>，可长缓存），
    // 没有该字段（方块接口不返回 icon_url）时回落 /{items|blocks}/{full_id}/icon。
    function iconUrl(kind, name) {
        const meta = metaOf(kind, name);
        if (meta && meta.icon_url) return absoluteApiUrl(meta.icon_url);
        return API_BASE + '/' + metaEndpoint(kind) + '/' + encodeURIComponent(name) + '/icon';
    }

    // fluid 用方块接口；block（外设方块）也用方块接口；其余用物品接口
    function metaEndpoint(kind) {
        return (kind === 'fluid' || kind === 'block') ? 'blocks' : 'items';
    }

    // 外设名（create:basin_0）-> 方块 id（create:basin）：去掉结尾的 _数字
    function blockIdOf(peripheralName) {
        return String(peripheralName || '').replace(/_\d+$/, '');
    }

    // 方块 id 候选：CC:T 报出的外设名可能不带命名空间（红石继电器 → redstone_relay_0，
    // 箱子 → chest_0，动力轴承 → bearing_0 …），于是 blockIdOf 给出的裸名字既不在 icon-exports
    // 元数据里（那边登记的是 computercraft:redstone_relay / minecraft:chest / create:bearing），
    // blocksitems 的 /blocks/lookup/<裸名字> 也查不到 —— 外设卡片就只剩名称字形
    // （用户第 2 项要求：红石继电器要用 computercraft:redstone_relay 的方块图标）。
    // 候选顺序：① CC 自己的方块（computercraft:xxx）② 原版方块（minecraft:xxx）
    // ③ 本地导出里路径唯一命中的方块（create:bearing 这种模组方块；多个模组同名时不猜）
    // ④ 裸名字（保持老行为）。本来就带命名空间的（create:basin）只有一个候选，行为完全不变。
    const BLOCK_ID_NAMESPACES = ['computercraft', 'minecraft'];

    // 个别外设名与方块 id 对不上，需要直接指定（用户第 3 项：海龟 → computercraft:turtle_advanced）。
    // CC:T 把海龟外设报成 "turtle_N"，而它在游戏里是 turtle_normal / turtle_advanced 两种方块；
    // 光看外设类型分不出是哪种（外设类型都是 turtle），统一用高级版 —— 图标准确，标签也对得上。
    const PERIPHERAL_BLOCK_OVERRIDES = { turtle: 'computercraft:turtle_advanced' };

    function blockIdCandidates(peripheralName) {
        const raw = blockIdOf(peripheralName);
        if (!raw) return [];
        const override = PERIPHERAL_BLOCK_OVERRIDES[raw];
        if (override) return [override];
        if (raw.indexOf(':') >= 0) return [raw];
        const candidates = BLOCK_ID_NAMESPACES.map(function (namespace) { return namespace + ':' + raw; });
        const unique = iconExportUniqueIdByPath(raw);
        if (unique) candidates.push(unique);
        candidates.push(raw);
        return candidates;
    }

    // 从候选里挑一个确实存在的方块 id（图标与名字都用它）：
    //   ① 本地导出元数据里有这个方块（最可靠：icon-exports 就是按游戏里的方块导出的）
    //   → ② blocksitems 已经确认有这个方块 → ③ 都还没确认：先用第一个候选（computercraft:xxx），
    //      接口/元数据回来重画时会自动纠正（这一步保证首屏问的就是带命名空间的那个 id）。
    function resolvedBlockIdOf(peripheralName) {
        const candidates = blockIdCandidates(peripheralName);
        if (candidates.length <= 1) return candidates[0] || '';
        for (let i = 0; i < candidates.length; i += 1) {
            if (iconExportEntry('block', candidates[i])) return candidates[i];
        }
        for (let i = 0; i < candidates.length; i += 1) {
            if (metaState(resourceKey('block', candidates[i])) === 'ready') return candidates[i];
        }
        return candidates[0];
    }

    // 外设卡片图标：优先用该外设对应方块的图标；拿不到方块元信息就用字形兜底
    // （图片本身加载失败时由 ifmIconFallback 兜底）
    function blockIconHtml(peripheralName) {
        const blockId = resolvedBlockIdOf(peripheralName);
        if (!blockId) return faGlyphHtml('block', peripheralName);
        const key = resourceKey('block', blockId);
        // 与 iconHtml 同一套优先级：① 本地导出图（icon-exports，方块物品也有导出；接口的方块图标
        // 只有 /blocks/<id>/icon 一条路，模组没被收录时它必然 404）→ ② 接口图片。
        // 接口没明确说“没有这个方块”就先请求图片，图片真 404 时再由 onerror 换成名称兜底
        // （以前元信息没到时会先显示通用字形，像图标没引用上）
        const exported = iconExportFile('block', blockId);
        if (exported || (metaState(key) !== 'missing' && !iconFailedKeys.has(key))) {
            return iconImgTagHtml('block', blockId, ' title="' + escapeHtml(blockId) +
                '" style="width:20px;height:20px;image-rendering:pixelated"', exported);
        }
        queueMeta('block', blockId);
        return faGlyphHtml('block', peripheralName);
    }

    
