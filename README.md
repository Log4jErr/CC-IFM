[English](#en) | [中文](#zh)
<a id="zh"></a>
# CC-IFM 集成工厂管理终端

## 这是什么
- 一个 Minecraft **CC:Tweaked** 脚本 + 网页终端：把工厂里的容器、机器与流程集中起来管理。网页上既能看库存/流体，也能定义流程（合成、输入、输出、等待、红石信号…）、让机器自动取料与产出、往输出容器发货 —— **全程不用打开 Minecraft 客户端**。
- 一台计算机当**主控**（IFMMaster.lua，跑逻辑与网页通信），同一有线网络上可以再放若干**从节点**（IFMWorker.lua，分担容器扫描与物品/流体搬运）。
- 多台计算机与浏览器通过 itty-sockets（WebSocket 广播中继）通信，同一个“房间号”就是同一套工厂。

## 安装
- 在 CC:Tweaked 计算机里运行下面这一条命令即可（会自动解包出 `IFMMaster.lua`、`IFMWorker.lua` 与 `ifm/*.lua`）：
```
wget run https://raw.githubusercontent.com/Log4jErr/CC-IFM/main/backend/ifm_bundle.lua
```
- 直接从 URL 运行时计算机磁盘上并没有这个文件，所以脚本**不会删除任何文件**（先 `wget` 下载再运行的情况下，解包器会把自己删掉，避免留下垃圾文件）。
- 前提条件：安装 CC:Tweaked；有线网络里接上容器外设（`inventory`，例如 Create 的箱子）与流体外设（`fluid_storage`，例如储罐）；红石流程需要 Create 的 `redstone_relay`（其它提供 `redstone_relay` 外设的方块也行）。

## 启动
- 主控（房间号任选，但请足够复杂，否则可能撞进别人的房间）：
```
IFMMaster.lua --room my-complex-room-name
```
- 从节点（可选，越多扫描/搬运越快；必须和主控在同一有线网络上）：
```
IFMWorker.lua
```
- 可选参数：`--relay <ws-base-url>` 换用自建中转、`--random-room` 随机房间号并写回 `config.json`。

## 网页终端
- 在 PC 上把 `frontend/` 用 HTTP 提供出来（不要直接双击 index.html：拼音库/翻译模型/图标导出都走相对路径）：
```
cd frontend
python serve.py            # 默认 http://localhost:8000/index.html
```
- 浏览器打开页面 → 填**同样的房间号**（和 `--room` 一致）→ 连接。
- 也可以把 `frontend/` 整个目录放到任意静态托管（例如 GitHub Pages）再访问。

## 能做什么
- **资源**：库存/流体浏览、搜索（支持中文拼音，例如 `gzt` → 工作台）、排序、点击增减待发送数量、中键设发送数量、Shift+中键设合成数量。
- **流程**：定义机器的输入/输出/等待/红石步骤，支持按批翻倍、上游按需触发，依赖图上直接显示「正在合成 / 剩余目标」。
- **外设与定义**：容器角色（存储 / 输入 / 输出 / 交互）、机器类型与机器、红石信号；把外设卡片拖到对应卡片即可设定，拖出即删除。
- **输入容器**：像扫存储容器一样定期扫描，里面的东西会自动搬进存储容器。
- **发货**：把存储容器里的物品/流体发送到输出容器，底部面板有「待发送 / 发送中」进度与取消。
- **整理**：把散落在多个槽位/容器里的同一物品合并，计划分批计算，不卡主控。

## 什么原理
- 浏览器与服务端通过 **itty-sockets** 中转的 WebSocket 互相传递消息；服务端只发**增量**，有变化立刻推送（不做速率硬限制）。
- 物品图标与元信息三层优先：① 本地 `frontend/icon-exports/` 导出（离线可用、与游戏内一致）→ ② blocksitems.com 接口 → ③ 名称兜底；物品名只在存在**当前语言**的元数据时才用导出的名字。
- 物品名称可选用 **Bergamot** 本地翻译（英→中）：把模型放进 `frontend/web/models/en-zh/`（或让页面从 CDN 拉）；控制台可用 `await IFMTranslate.translateText('Andesite Casing')` 试效果。
- 中文拼音搜索由 `frontend/dist/pinyinlite_full.min.js` 提供（缺失时自动退回中英文关键词匹配）。

## 高级
- 开机自启主控（`startup.lua`）：
```lua
shell.run("bg", "IFMMaster.lua", "--room", "YOUR ROOM NAME")
```
- 开机自启从节点：
```lua
shell.run("bg", "IFMWorker.lua")
```
- 容器扫描间隔（存储容器 / 输入容器）用网页上的「设置」面板调整，写入 `config.json` 的 `settings.scan`。
- 改了后端源码之后重新编译：`python backend/build.py`，产物是 `backend/ifm_bundle.lua`。

## 限制
- 由于 CC:Tweaked 的限制，计算机所在区块必须保持加载，否则脚本会停摆（记得准备区块加载手段）。
- 公共中继 `wss://itty.ws/c/` 在部分地区可能连不上，可以自建 itty-sockets 服务器并用 `--relay` 指过去。
- 读容器是阻塞调用（有线网络上每个容器约 1 个服务器刻），容器很多时扫描会变慢 —— 可以调大扫描间隔。
- 从节点只分担**容器扫描与物品/流体搬运**；流程逻辑始终由主控执行。


[English](#en) | [中文](#zh)
<a id="en"></a>
# CC-IFM Integrated Factory Manager

## What is that?
- A Minecraft **CC:Tweaked** script plus a web terminal that manages a whole factory: browse item/fluid stock, define processes (craft, insert, extract, waits, redstone), let machines pull materials and push products automatically, and deliver items into output containers — **without opening the Minecraft client**.
- One computer runs as the **master** (`IFMMaster.lua`, logic + web link); optional **workers** (`IFMWorker.lua`) share container scanning and item/fluid moves over the same wired network.
- Computers and the browser talk through an itty-sockets relay: the same room name means the same factory.

## Installation
- Run this single command in a CC:Tweaked computer (it unpacks `IFMMaster.lua`, `IFMWorker.lua` and `ifm/*.lua`):
```
wget run https://raw.githubusercontent.com/Log4jErr/CC-IFM/main/backend/ifm_bundle.lua
```
- When run straight from a URL nothing exists on the computer disk, so the script **deletes nothing** (if you downloaded the file first, the unpacker deletes itself to keep the disk clean).
- Requirements: CC:Tweaked; wired peripherals — `inventory` containers and `fluid_storage` tanks; `redstone_relay` (from Create) for redstone steps.

## Booting
- Master (pick a complex room name, otherwise you may join someone else's room):
```
IFMMaster.lua --room my-complex-room-name
```
- Workers (optional, they must share the wired network with the master):
```
IFMWorker.lua
```
- Extra flags: `--relay <ws-base-url>` for your own relay, `--random-room` to generate and store a room name.

## Web terminal
- Serve the `frontend/` folder over HTTP (do not open index.html directly — the pinyin library, translation models and icon exports are relative paths):
```
cd frontend
python serve.py            # http://localhost:8000/index.html by default
```
- Open the page, enter the **same room name**, connect. You can also publish `frontend/` on any static host (GitHub Pages works).

## Features
- **Resources**: item/fluid stock, search (Chinese pinyin supported, e.g. `gzt` → crafting table), sorting, click to change the send amount, middle click to set the send amount, Shift+middle to set the craft amount.
- **Processes**: machine inputs/outputs/waits/redstone steps, batch multiplication, upstream on-demand crafting, live “crafting / left to craft” counters on the dependency graph.
- **Peripherals & definitions**: container roles (storage / input / output / interaction), machine types, machines, redstone signals — drag peripheral cards onto a card to assign, drag out to remove.
- **Input containers**: scanned periodically like storage containers; their content is moved into storage automatically.
- **Sending**: deliver items/fluids from storage into output containers, with pending/in-flight lists and cancel.
- **Compact**: merge identical stacks scattered over slots/containers, planned in small slices so the master stays responsive.

## Theorum
- Browser and script exchange messages over an **itty-sockets** relay; the master pushes incremental changes as soon as they happen (no hard packet rate limit).
- Icon/metadata lookup has three tiers: ① local `frontend/icon-exports/` export → ② blocksitems.com API → ③ name fallback. Exported display names are used only when the metadata file of the **current language** exists.
- Item names can be translated locally with **Bergamot** (EN→ZH) using the models in `frontend/web/models/en-zh/`; try it in the console with `await IFMTranslate.translateText('Andesite Casing')`.
- Chinese pinyin search comes from `frontend/dist/pinyinlite_full.min.js` (falls back to plain keyword search when missing).

## Startup
- Auto-start the master from `startup.lua`:
```lua
shell.run("bg", "IFMMaster.lua", "--room", "YOUR ROOM NAME")
```
- Auto-start a worker:
```lua
shell.run("bg", "IFMWorker.lua")
```
- Container scan intervals (storage / input) are configurable from the web “Settings” panel (stored in `config.json` → `settings.scan`).
- Rebuild the bundle after backend changes: `python backend/build.py` (writes `backend/ifm_bundle.lua`).

## Limitation
- CC:Tweaked keeps a computer running only while its chunk is loaded — use a chunk loader.
- The public relay `wss://itty.ws/c/` is unreachable in some regions; host your own itty-sockets server and pass it with `--relay`.
- Container reads are blocking (about one server tick per container on wired networks), so scan intervals matter on large factories.
- Workers only offload container scans and moves; process logic always runs on the master.
