```
      _/_/_/  _/_/_/_/  _/      _/ 
       _/    _/        _/_/  _/_/    Integrated
      _/    _/_/_/    _/  _/  _/    Factory
     _/    _/        _/      _/    Manager
  _/_/_/  _/        _/      _/     
```

[English](#en) | [中文](#zh)
<a id="zh"></a>

# CC-IFM 集成工厂管理
## 这是什么
- 一个 Minecraft CC:Tweaked 脚本。通过定义流程进行自动合成，就像AE2、Integrated Dynamics、或者说Super Factory Manager那样。设定好一切后，只需要点击合成目标产物，就可以看着各种材料经过你的机器，逐步合成并呈递你的目标产物。
- 并且，可以通过浏览器访问并管理你的工厂，而无需打开Minecraft客户端。

## 运行环境说明
- Minecraft服务器安装了CC:Tweaked。这是必要的废话，IFM在CC:Tweaked的计算机上运行
- 搭建了正确的网络拓扑结构，你需要使用和线缆将工厂的各个部分连接。具体来说，对于每个 计算机/存储容器（箱子、木桶、或者其他模组提供的抽屉之类，或者各种流体储罐）/机器，需要连接到有线调制解调器(无线的不行，CC:Tweaked提供了片式和块式的两种有线调制解调器，都可以)，并且用线缆连接所有有线调制解调器。
- 在整个IFM系统中，你至少要接入一台计算机，而由于物品/流体调度非常耗时，为了提高运行速度，你可以尽情添加更多的计算机。IFM是分布式的，其中一台计算机作为主控节点（IFMMaster），其余计算机作为受控节点（IFMWorker）。可以在没有IFMWorker的情况下运行，但不推荐，除非你能忍受蜗牛速度。

## 安装
- 在IFM网络的所有计算机使用下面这一条命令进行安装
```
wget run https://raw.githubusercontent.com/Log4jErr/CC-IFM/main/backend/ifm_bundle.lua
```
- 如果IFM有更新的版本，你可以重新运行这条命令以完成更新。
- 如果服务器内无法访问Github，你可以单独下载ifm_bundle.lua，然后将此文件拖拽上传至计算机，运行ifm_bundle.lua以完成安装。
- 软件安装会安装到同级目录的 `ifm/` 目录中

## 启动
- 在其中一台计算机中运行主控脚本，使用下面这条命令启动（警告：不要有复数台计算机在同一有线网络中运行主控脚本，否则会发生不可预料的结果）
```
ifm/IFMMaster.lua
```
启动后，你会看见屏幕上显示房间号，记下这个房间号，它是你浏览器连接的凭据。
- （高级）房间号是随机生成的，你可以自己指定房间号，启动参数添加--room <房间号>即可。
- （可选）在其余计算机启动从节点脚本：
```
ifm/IFMWorker.lua
```
主从节点之间会自动发现，所以不需要你进行其他干预。
- 主控与从节点的版本必须完全一致：版本号对不上时，两边互相拒绝执行搬运/查询（主控不派活、从节点拒绝执行并在屏幕上提示），网页上的从节点卡片也会标红。升级时把所有计算机一起升到同一版本。

## 网页终端
- 浏览器打开[这个页面](https://log4jerr.github.io/CC-IFM/frontend/)，这就是网页终端。
- 你需要在网页终端输入房间号以连接到你游戏内的IFM系统。

## 能做什么
- 库存浏览：浏览存储的所有物品/流体、支持排序、搜索（支持拼音搜素）。
- 发货：设定好一个容器作为输出容器，然后你可以指定物品/流体以及数量，将它们移动至输出容器。
- 存储优化：自动在存储容器之间合并，交换物品，从而腾出空间。这个整理算法会基于槽位容量和物品堆叠数进行合理的移动，让数量多的物品移动到大容量槽位（比如抽屉）。
- 卸货：设定一个容器作为输入容器，然后里面的物品会被自动取走并放入存储容器。
- 通用自动合成：这一部分是最复杂的，不能一句话说清楚，看下面的段落

## 自动合成系统
- 就像是AE2里的样板一样，IFM的自动合成需要你进行“流程”和“机器”的定义。
- 首先是机器定义，你需要先新建“机器类型”，这一层抽象是为了进行机器的并行（例如，你有很多个酿造台，它们每一个都能执行酿造配方，那么想要IFM使用你的酿造台，不妨创建并命名一个机器类型叫做“炼药”）。
- 接下来，在机器类型卡片下创建“机器”，机器是一个最小的工作单位。机器需要设定输入容器、输出容器、以及一个可选的红石信号（IFM系统中允许接入红石继电器，按照你设定的要求发送或者等待红石信号，这在有些时候很有用）。对于酿造台这个例子，酿造台需要同时添加为输入容器和输出容器（你既对它输入材料，又直接从它抽出成品）。一些机器可能会有多个输入/输出容器（举个例子，机械动力的“机械手装配”，需要同时对机械手和下方的置物台输入材料，那么你应当将它们都设置为输入容器。）
- 机器定义中还有一些其他参数，例如“并行信号量”是这个机器可以同时接受的合成任务数。默认值为1表示这个机器必须要在输入物品后，产物完全输出后，才能进行下一次物品输入。一些机器可能能够同时支持多个任务，比如通过漏斗+堆肥桶进行堆肥的机器，漏斗可以同时输入多组物品，那么你不妨将这个值设置高一些。（AE2玩家会很明白，这有点像是样板供应器设置为“阻塞直到产物返回”）
- 一个机器类型下可以有多个机器，这很好理解。如果要使用一类机器合成，可以使用这些机器中任意一个空闲的机器。
- 接下来，创建“流程”，流程是一个使用机器进行一次合成的完整步骤，比如我们可能希望用1x 下界疣+3x 水瓶合成3x 粗制的药水，不妨将其创建为流程。对于这个药水合成例子，你需要将创建的流程关联到炼药机器，设定输入的材料(1x下界疣+3x水瓶)和抽取的产物(3x粗制的药水)。有的时候机器有多个输入/输出容器，而且你需要控制材料具体输入到哪个容器，那么你得设置“机器序号”。有的时候你还要更精确的控制材料输入到容器的哪个槽位，那么“槽位序号”就是你所需要的设置。（吐槽一句，大多数Minecraft物流/自动合成模组都没有指定槽位输入输出的功能）。
- IFM的产物抽取行为非常智能，它只会抽取你指定的物品，忽略其他物品。所以对于这个酿造例子，你不用像Minecraft原版自动炼药那样，使用红石线路进行定时门控...并且你还可以更精确地指定抽取的容器和抽取的槽位。
- 一个流程的运行很简单，首先按顺序将材料输入，然后按顺序将产物抽出。如果没法输入材料，流程会保持等待直到材料输入。如果产物没法抽出，也会保持等待直到能够抽出产物。
- 流程还有一个“最大翻倍数”的设定，如果你要合成不止一个物品，IFM会按照你设定的翻倍数，将输入材料翻倍，同时输入机器，并且期待翻倍的产物输出。例如你希望用Minecraft原版的合成器合成雪块（1x雪球输入槽位1，1x雪球输入槽位2，1x雪球输入槽位3，1x雪球输入槽位4 -> 1x雪块），那么翻倍数不妨设置为16（因为雪球在合成器内可以按16个堆叠）
- 除了物品和流体的输入输出，流程中还可以定义其他的操作，定时等待就是按顺序执行到这一步时流程要至少等待这么多时间。红石信号相关操作需要你接入红石继电器，然后可以等待红石继电器有信号，或者靠红石继电器发出信号。（显然，你可以编码一个流程用来演奏红石音乐）
- NBT忽略：你可以指定忽略物品NBT，默认不开（要求NBT完全匹配）
- 产物的“最少数量”和“最多数量”：这个设置是针对概率合成的，即产物数量不确定（有时多有时少），计算发配数时会按照“最多数量”计算（IFM很乐观地认为能够得到所有产物，如果做不到就重来以合成剩余部分），并且抽取产物也按照“最多数量”来（也就是说，不会多抽超过最多数量的产物）。“最少数量”则用于判断抽取操作是否完成，也就是最坏情况。

## 什么原理
- 浏览器与服务端通过 itty-sockets 中转的 WebSocket 互相传递消息
- 前端图标和资源信息按照三个方案获取：本地 `frontend/icon-exports/` 导出（质量最佳，但是需要根据Minecraft实例专门导出）→ blocksitems.com 接口（质量很好，不过有些物品缺失，并且不支持国际化）→ 注册名转换（没有图标。你可以按右上角翻译按钮启用Bergamot翻译器以获取你的语言的物品名称，质量较差）。
- 本地导出按注册名匹配：同一个注册名下的多条 NBT 变体里挑 NBT 最接近的那条（调用方知道物品的 NBT 时按“完全一致 → 最接近”排序），只有在导出元数据里完全没有这个注册名时才回退到 blocksitems 接口。也就是说 NBT 不同不会让图标掉到接口层。

## 调度器（1.7.0）
- 主控每 1 游戏刻（50ms） 唤醒一次调度器；上一轮跑完才开始下一轮计时，所以一轮偶尔超时也不会积压 timer 事件。网页请求、worker 回报（modem）都在两次调度之间照常处理。
- 每个来源一条队列，队列之间轮转，每条队列有独立的时间片（每次轮到自己最多执行几步，网页「设置」面板可调，正整数 1~50）：<br>
  `process` 流程处理 · `storageScan` 存储容器扫描 · `inputScan` 输入容器扫描 · `inventoryIn` 库存输入（送料/入库） · `inventoryOut` 库存输出（抽取/发货） · `compact` 容器整理 · `detail` 物品详情 · `manual` 手动操作（交互容器搬运）。
- 队列推进规则：有 worker 且都忙 → 本次不推进队列（写盘/心跳/超时/重发/推送照做）；没有 worker → 主控本机执行，且每次调度只推进一步；任务失败/未完成时按队列策略处理（流程队列回队尾继续均匀推进；入库/出库/整理/手动/详情的搬运失败即丢弃，由生成器下次重建）。
- 容器内容是快照：扫描（storageScan / inputScan 队列，worker 代读或本机读）写入权威基准；搬运不再自己扫描，只按快照的可见值挑源槽位/数量，并且出库前先扣快照、结算时按实际搬运量归还差额，因此两个出库任务不会争抢同一堆（下一个扫描会把基准纠正回来）。详情的 `getItemDetail` 一步只做一次、失败丢弃。
- 因此不再有“存储/输入容器扫描间隔”“每 tick 最多派几条”“worker 代扫冷却”这类硬间隔：节奏完全由队列轮转 + 时间片决定。1.7.0 起 `settings.scan` 已删除。
- 拼音搜索库借助 `pinyinlite` 提供
- 前端部署依赖 `Github Pages`

## 高级
- 开机自启主控（创建一个`startup.lua`脚本，内容如下）：
```lua
shell.run("bg", "ifm/IFMMaster.lua")
```
- 自定义房间号
```
ifm/IFMMaster --room <房间号>
```
- 开机自启从节点（创建一个`startup.lua`脚本，内容如下）：
```lua
shell.run("bg", "ifm/IFMWorker.lua")
```
- 如果修改后端源码，重新编译为单文件产物：`python backend/build.py`，产物是 `backend/ifm_bundle.lua`。
- 顺手跑两个后端静态/模块检查：`node backend/tools/check_merged_statements.js`（找出"两条语句被合并到一行"的历史损坏——曾被这种损坏把 `addQueue` 覆盖成默认空跑，导致 worker 永远空闲、什么都不发生，而语法检查查不出来）；`node backend/tools/run_module_tests.js`（调度器/快照/中继协议的行为断言）。
- 如果改了调度器 / 容器快照（`dispatch.lua`、`containers.lua`），跑一遍模块自测：在 `backend/` 里执行 `node tools/run_module_tests.js`（需要 `npm install fengari --no-save`）。它把这两个模块原样加载进真 Lua 虚拟机，用桩替换外设，断言队列轮转/时间片/回队尾/丢弃/在飞、全忙暂停、本机模式、快照预留不超发与结算归还等不变量。
- 如果改了 `index.html` 或 `web/*.js`，在 `frontend/` 里跑前端冒烟测试：`node run_dom_smoke.js`。它用一套极小的 DOM 桩把 10 个脚本按 index.html 的顺序原样加载，再模拟「填房间号 → 点连接」；并额外用 jsdom（浏览器同款解析器） 检查 index.html：JS 引用的每个 id 是否真的解析得出来、有没有编码事故（U+FFFD/乱码）、`data-ifm-build` 与 `?v=`、`IFM_APP_BUILD` 三处构建号是否一致。装一次依赖：`npm install jsdom --no-save`。
  注意：不要用 PowerShell 的 `Get-Content/Set-Content` 改写 `index.html`（会把 UTF-8 中文变成乱码、还会吃掉引号与 `<`，让元素被解析器吞掉——这正是"点连接没反应 / missing element #sendBtn"的成因）。要改就用编辑器直接改，或只改 `data-ifm-build` 与 `?v=` 两个数字。
- 主控的数据文件放在安装目录下的 `ifm/data/` 里，从节点自身不保存数据。
- icon-export来自于IconExporter，你可以部署自己的网页实例，然后用你的Minecraft实例导出的物品图标和元数据替换掉icon-exports
## 编码规范

* 未定义的行为必须报错，不许静默失败（用户第 1 项要求）。典型反例与现在的处理：
  * 队列没注册 `run` → 注册时立刻 `log` 报错 + 计数（`missingRunner`），任务被丢弃时也留一行日志；
    不接受"默认空跑"这种"看起来正常"的写法。
  * 同名队列被注册两次 → 记 `duplicateQueues` 并打日志（字段是合并而不是覆盖：
    `run` 不传就保留原值 —— 早期正是"覆盖成默认空跑"导致 worker 永远空闲、网页一片空白却不报错）。
  * 空闲流程出现在流程队列里 → 打 `BUG:` 日志 + `idleProcessInQueue` 计数，而不是静默出队。
  * 这些计数都会出现在 `diagnose` 的 `scheduler guards:` 一行里；不是 0 就说明代码有 bug。
* 抓不到的错也要留下痕迹：所有 `pcall` 失败都必须 `log`（调度器的任务、生成器、维护回调都这么做）。
* 历史损坏（"两条语句被合并到一行"）用 `node backend/tools/check_merged_statements.js` 静态查。

## 限制
- 计算机所在区块必须保持加载，否则脚本会停摆（记得准备区块加载手段）。
- 外设在有线线缆上最多传递256格，所以不要让线缆超过这个长度，不然找不到外设。
- 公共中继 `wss://itty.ws/c/` 在部分地区可能连不上，可以自建 itty-sockets 服务器并用 `--relay` 指过去。
- 服务端如果一直打印 `WebSocket closed by relay (...) after Ns`，先看括号里的原因：只活了几秒 + 中继侧原因 = 中继（或到它的链路）在掉线（建议自建 itty-sockets）；括号里没有原因通常是链路静默断开。每 30 秒的状态行会显示 `link: up=..s idle=..s closes=..`，`diagnose` 的 `protocol link:` 段有同样的计数，据此可以区分「一条连接活了几小时」和「每 5 秒换一条连接」。
- 读容器是阻塞调用（每个容器每次读取约1Tick），容器很多时扫描会变慢，可以调大扫描间隔，或者添加更多从节点。

## 小工具
- backend/tools下是一些其他的CC脚本，提供一些用得着的功能。这些脚本各自独立运行。

### netsync
- 你有1个主控和一大堆从节点，现在IFM版本更新了，一个个去更新可太麻烦了。工具脚本netserver和netsync是成对使用的，用于自动同步文件。
- netserver和netsync启动时需要指定name，相同的name之间的netserver会把文件同步给netsync。
- netserver脚本同目录下两个配置文件决定要同步哪些内容：`syncinclude.txt`中设置要同步的路径，每行一个，可以是文件也可以是路径（目录末尾写 `/`），`syncignore.txt`设置要忽略的路径，同样是每行一个。
- netserver会按照相同的目录树将文件同步至客户端
- netsync只会在netserver有更新的版本时才下载。否则会保持等待。
- netserver 启动时会把同步范围内文件计算哈希，哈希和之前不同时才进行同步。
- 为了使用这个脚本自动更新IFM，你应当在主控节点安装netserver，设置同步目录为/ifm/，设置排除目录为/ifm/data/，在从节点安装netsync，并且在从节点运行netsync。每次需要更新IFM版本时，先在主控安装新版IFM，然后在主控重启 netserver。你可能还需要设置从节点开机自启netsync（借助shell.run bg或者fg命令，你可以同时运行多个脚本，比如IFMWorker和netsync。）

### crafter
- 现在你希望使用IFM自动进行工作台合成，可Minecraft原版的合成器速度很慢（而且，很卡！），为此你可以使用海龟合成。
- 在海龟上安装crafter.lua这个脚本，就可以将海龟变为一个批量合成器。你可能需要写一个startup.lua脚本自启crafter脚本，(或者偷懒，直接将crafter脚本重命名为startup.lua)
- 海龟需要安装工作台，非合成海龟没有合成能力
- 搞定上面的设置后，海龟在每次接收到红石信号时，会从上方容器中抽取物品，然后将所有物品合成，然后将产物吐到下方容器（或者合成没成功，吐出所有材料）。
- 上方容器的1-9槽位分别对应工作台安装从左到右，从上到下的9个槽位。你知道的，你可以用IFM精确控制材料输入槽位。
- 下方可以不为容器，此时海龟会以物品形式吐出产物。如果产物实在是太多了，海龟物品栏装不下，也会以物品形式吐出。（例如，你用64x铁锭+64x燧石合成了64x打火石，海龟只能装下16x打火石，此时会有48x打火石以物品形式掉出）
- 相比合成器一次红石脉冲只能合成1次，海龟合成器每次可以将所有物品完成合成。（或者你的Minecraft版本比较低，没有合成器，此时这个海龟大概是你唯一的选择。）
- 为了使用IFM完全操控这个合成器，你应当需要在海龟旁安装一个红石继电器，并且设置IFM流程在输入所有物品后对此继电器发出红石脉冲。

[English](#en) | [中文](#zh)
<a id="en"></a>
# CC-IFM Integrated Factory Manager

## What is that?
- A Minecraft CC:Tweaked script. It auto-crafts through *process definitions*, much like AE2, Integrated Dynamics or Super Factory Manager. Once everything is set up you just click the target product and watch materials flow through your machines, being crafted step by step until the requested items show up.
- The same factory can be browsed and managed from a web browser, with no Minecraft client needed.

## Requirements
- CC:Tweaked installed on the Minecraft server. (Needless to say, IFM runs on a CC:Tweaked computer.)
- A correct network topology: you must connect every part of the factory with cable. Concretely, every computer / storage container (chest, barrel, drawers or other storage from other mods, any fluid tank) / machine must be attached to a wired modem (wireless will not do; CC:Tweaked ships both cased and full-block wired modems, either works), and all wired modems must be joined with networking cable.
- At least one computer in the whole IFM system. Item/fluid scheduling is expensive, so add as many computers as you like to speed it up. IFM is distributed: one computer is the master (`IFMMaster`), the others are workers (`IFMWorker`). Running without workers is possible but not recommended unless you can live with snail speed.

## Installation
- Run this single command on every computer of the IFM network:
```
wget run https://raw.githubusercontent.com/Log4jErr/CC-IFM/main/backend/ifm_bundle.lua
```
- When a new version is released, run the same command again to update.
- If GitHub is unreachable from your server, download `ifm_bundle.lua` separately, drag it onto the computer and run it to install.
- The bundle installs into the `ifm/` directory next to it.

## Booting
- Run the master script on one of the computers (warning: never run the master on two computers of the same wired network, the result is unpredictable):
```
ifm/IFMMaster.lua
```
After it starts, the room name is shown on screen - note it down, it is the credential your browser uses to connect.
- (Advanced) The room name is generated randomly; pass `--room <room>` to choose your own.
- (Optional) Start the worker script on the remaining computers:
```
ifm/IFMWorker.lua
```
Master and workers discover each other automatically, so no further action is needed.
- Master and workers must run exactly the same version: when the version strings differ they refuse to run moves/queries for each other (the master stops dispatching, the worker refuses and prints a hint, and the worker card is flagged in the web UI). Update every computer together.

## Web terminal
- Open [this page](https://log4jerr.github.io/CC-IFM/frontend/) in your browser - that is the web terminal.
- Enter the room name in the web terminal to connect to your in-game IFM system.

For development you can also serve the frontend locally: `cd frontend` then `python serve.py` (opens http://localhost:8000/index.html).

## Features
- Stock browsing: browse all stored items/fluids, with sorting and search (pinyin search supported).
- Delivery: mark a container as an output container, then pick items/fluids and amounts to move them there.
- Storage optimisation: automatically merges and swaps items between storage containers to free space. The algorithm moves stacks according to slot capacity and stack size, e.g. moving large amounts into high-capacity slots (drawers).
- Unloading: mark a container as an input container; anything inside it is taken out and moved into storage automatically.
- General-purpose auto-crafting: the most complex part - it cannot be described in one sentence, see the next section.

## Auto-crafting system
- Just like AE2 patterns, IFM auto-crafting needs machine and process definitions.
- First create a machine type. That abstraction layer exists so machines can work in parallel (if you own several brewing stands that can all brew, create and name a machine type such as "Brewing" and let IFM use your stands).
- Next create a machine under that machine type; a machine is the smallest working unit. It needs input container(s), output container(s) and an optional redstone signal (IFM can use a redstone relay to send or wait for signals, which is handy at times). For the brewing stand example, add the stand both as input and output container (you insert materials into it and pull products straight out of it). Some machines have several input/output containers (e.g. Create's Mechanical Arm assembly needs materials inserted into both the arm and the depot below it - mark both as input containers).
- Machines have a few more parameters, e.g. parallel signals is how many crafting jobs the machine accepts at the same time. The default 1 means the machine must have inserted a job and fully extracted its products before new materials may be inserted. Some machines handle several jobs at once - e.g. a hopper feeding a composter can accept multiple stacks, so raise the value there. (AE2 players will recognise this as a Pattern Provider set to "block until products return".)
- One machine type can contain many machines; when crafting with that type, any idle machine of that type can be used.
- Next create a process: the complete set of steps that performs one craft on a machine. Say we want 3x Awkward Potion from 1x Nether Wart + 3x Water Bottle - make that a process. For the potion example, link the process to the brewing machine and set the inserted materials (1x Nether Wart + 3x Water Bottle) and the extracted products (3x Awkward Potion). When a machine has several input/output containers and you need to control which container receives the materials, set the machine index; when you need to control which slot inside that container receives them, set the slot index. (Most Minecraft logistics/autocrafting mods cannot do slot-precise I/O at all.)
- Product extraction is smart: IFM only extracts the items you specify and ignores everything else. So the brewing example needs no redstone gating like vanilla auto-brewing - and you can be even more precise about which container and which slot to extract from.
- A process runs simply: materials are inserted in order, then products are extracted in order. If materials cannot be inserted, the process waits until they can; if products cannot be extracted, it also waits until they can.
- Processes also have a max multiplier: to craft more than one item, IFM multiplies the input materials by that factor, inserts them together and expects the multiplied products. For example, to craft Snow Blocks in the vanilla Crafter (1x Snowball into slots 1..4 -> 1x Snow Block), set the multiplier to 16 (snowballs stack to 16 in the crafter).
- Besides item/fluid I/O, processes support other steps: a timed wait holds the process for at least that long when reached in order; redstone steps need a redstone relay and can wait for a signal or emit one. (Obviously you can encode a process that plays redstone music.)
- Ignore NBT: you can ignore item NBT (off by default, which requires NBT to match exactly).
- Products' minimum and maximum counts target chance-based recipes whose output amount is uncertain. Distribution counts are computed from the maximum (IFM optimistically assumes it can get all products, and retries to craft the remainder if it cannot), and product extraction also uses the maximum (so it never over-extracts). The minimum is used to decide whether an extraction is complete, i.e. the worst case.

## How it works
- Browser and script exchange messages over a WebSocket relayed by itty-sockets.
- Icons and resource info are fetched in three fallback tiers: local `frontend/icon-exports/` export (best quality, but must be exported from your own Minecraft instance) -> blocksitems.com API (good quality, but some items are missing and it is not internationalised) -> registry name conversion (no icon; press the translate button top-right to enable the Bergamot translator and get item names in your own language, lower quality).
- The local export is matched by registry name: among the several NBT variants registered for one id, the closest NBT wins (an exact match is preferred when the caller knows the item's NBT). The blocksitems API is only used when the export metadata has no entry at all for that registry name, so a different NBT never pushes the icon down to the API tier.

## Scheduler (1.7.0)
- The master wakes the scheduler once per game tick (50 ms); the next timer is armed only after the previous run finished, so an occasional long run never piles up timer events. Web requests and worker replies (modem) are still handled between two scheduler runs.
- One queue per source, rotated round-robin, each with its own time slice (max steps per turn, editable in the web "Settings" panel, positive integer 1~50): `process`, `storageScan`, `inputScan`, `inventoryIn`, `inventoryOut`, `compact`, `detail`, `manual`.
- Queue advancement: all workers busy → nothing advances this run (disk writes / heartbeat / timeouts / resends / pushes still happen); no worker at all → the master runs it locally, one step per scheduler run; failures follow the queue policy (the process queue re-appends to the tail so every process advances evenly; move/detail tasks are dropped on failure and regenerated later).
- Container contents are a snapshot: scans (storageScan / inputScan queues, done by a worker or locally) write the authoritative base; moves never scan - they pick source slot/amount from the snapshot's visible value, reserve on the source before dispatching and refund the difference once the real moved amount is known, so two out-tasks can never claim the same stack (the next scan corrects the base). `getItemDetail` runs exactly once per step and is dropped on failure.
- Consequently there are no more hard intervals (storage/input scan intervals, per-tick dispatch caps, delegated-scan cooldowns): the pace comes from queue rotation + time slices. `settings.scan` was removed in 1.7.0.
- Pinyin search is provided by the `pinyinlite` library.
- Frontend deployment relies on `Github Pages`.

## Advanced
- Auto-start the master (create a `startup.lua` with):
```lua
shell.run("bg", "ifm/IFMMaster.lua")
```
- Custom room name:
```
ifm/IFMMaster --room <room>
```
- Auto-start a worker (create a `startup.lua` with):
```lua
shell.run("bg", "ifm/IFMWorker.lua")
```
- After changing the backend source, rebuild it into a single file: `python backend/build.py` (writes `backend/ifm_bundle.lua`).
- Two quick backend checks: `node backend/tools/check_merged_statements.js` (finds historical "two statements merged into one line" damage - that once overwrote an `addQueue` with the default no-op runner, so workers stayed idle and nothing happened, and no syntax check could see it) and `node backend/tools/run_module_tests.js` (behavioural assertions for the scheduler / snapshot / relay protocol).
- After changing the scheduler or the container snapshot (`dispatch.lua`, `containers.lua`), run the module self-test from `backend/`: `node tools/run_module_tests.js` (needs `npm install fengari --no-save`). It loads those two modules as-is into a real Lua VM, swaps the peripherals for stubs, and asserts the invariants that are hard to eyeball: round-robin fairness, slices, retry-to-tail, drop, inflight, "all workers busy -> no advancement", local mode, "reservations never oversell" and "settlement refunds the difference".
- The master's data files live in `ifm/data/` inside the install directory; workers keep no data of their own.
- After changing `index.html` or `web/*.js`, run the frontend smoke test from `frontend/`: `node run_dom_smoke.js`. It loads all 10 scripts through a tiny DOM stub (in index.html order) and then simulates "type a room -> click connect"; it also parses index.html with jsdom (the same parser browsers use) to check that every id the JS looks up really exists in the DOM, that there is no encoding damage (U+FFFD/mojibake) and that `data-ifm-build`, `?v=` and `IFM_APP_BUILD` carry the same build number. One-time dependency: `npm install jsdom --no-save`.
  Never rewrite `index.html` with PowerShell `Get-Content/Set-Content` - it turns the UTF-8 Chinese into mojibake and eats quotes/`<`, which makes elements disappear from the parsed page (that is exactly what caused "clicking connect does nothing / missing element #sendBtn"). Edit it with a real editor, or change only the `data-ifm-build` and `?v=` numbers.

- After changing the frontend icon logic, run the icon self-test from `frontend/`: `node run_icon_tests.js` (drives the real `icon-exports-metadata/zh.json` and checks that every icon path prefers the local `icon-exports/` image, that the same registry name wins even when the NBT differs, that the *closest* NBT variant is picked, that a 404 export image switches to another variant of the same id before the API tier, and that a namespace-less peripheral name such as `redstone_relay_0` resolves to its block icon). The report also lists the ids whose registered png is not on disk (an export-completeness issue, not a frontend one).

## Coding conventions

* Undefined behaviour must raise/log an error - never fail silently (requested in user item 1). Typical cases and how they are handled now:
  * A queue registered without `run` -> logged + counted (`missingRunner`) at registration time, and every dropped task leaves a log line. "Default to a no-op runner" is not acceptable.
  * The same queue registered twice -> logged + counted (`duplicateQueues`), and the fields are merged instead of replaced (`run` is kept when the second call omits it). Early versions replaced it with a no-op runner, which made every worker look idle and the page show nothing while reporting no error at all.
  * An idle process sitting in the process queue -> logged as `BUG:` plus counted (`idleProcessInQueue`) instead of being silently dequeued.
  * All of these counters show up in the `scheduler guards:` line of `diagnose`; anything but 0 means there is a bug in the code.
* Leave a trace for swallowed errors: every failing `pcall` must be logged (the dispatcher does this for tasks, generators and the maintain callback).
* Historical damage ("two statements merged into one line") is caught statically by `node backend/tools/check_merged_statements.js`.

## Limitations
- The chunk the computer is in must stay loaded, otherwise the script stalls (get a chunk loader).
- Peripherals travel at most 256 blocks over wired cable, so do not exceed that length or they cannot be found.
- The public relay `wss://itty.ws/c/` cannot be reached in some regions; host your own itty-sockets server and point to it with `--relay`.
- If the server console keeps printing `WebSocket closed by relay (...) after Ns`, look at the reason in the brackets: a few seconds plus a relay-side reason means the relay (or the network path to it) is dropping you (self-host itty-sockets); no reason at all usually means the network died silently. The 30s status line shows `link: up=..s idle=..s closes=..` and `diagnose` → `protocol link:` shows the same counters, so you can tell "one socket kept alive for hours" from "a new socket every 5 seconds".
- Container reads are blocking (each container read takes about 1 tick), so large factories scan slowly - raise the scan intervals or add more workers.

## Tools
- `backend/tools/` holds a few extra CC scripts that provide some handy utilities. Each of them runs standalone.

### netsync
- You have one master and a pile of workers, and IFM just released a new version - updating them one by one is a pain. The `netserver` and `netsync` scripts are used as a pair to sync files automatically.
- `netserver` and `netsync` are started with a name; a `netserver` syncs its files to the `netsync`s with the same name.
- Two config files next to the `netserver` script decide what gets synced: `syncinclude.txt` (one path per line to sync; a directory ends with `/` and its contents are synced recursively) and `syncignore.txt` (one path per line to ignore). Both accept absolute paths (leading `/`, resolved from the filesystem root - `/ifm/` means the `ifm/` in the root directory, no matter where the script lives) and relative paths (relative to the directory of the `netserver` script); lines starting with `#` are comments, empty lines are ignored.
- Client-side layout = the server-side absolute path without the leading `/` (server `/ifm/x.lua` becomes client `/ifm/x.lua`): whatever layout the server has, the client gets the same.
- `netserver` needs the two config files, `syncinclude.txt` and `syncignore.txt`: the former lists the files or directories to sync (a directory path ends with `/`), the latter lists the paths to exclude.
- `netsync` only downloads when `netserver` has a newer version; otherwise it keeps waiting.
- The version number is automatic: on startup `netserver` hashes every file in the sync scope (path + size + content) and, when the result differs from the recorded `/netsync/<name>.hash`, bumps the version by one; when nothing changed it stays put. Just start `netserver` after editing files.
- On startup it prints how many files the sync rules matched and their total size (e.g. `sync rules matched 37 file(s), 412345 byte(s) in total`); when that is zero it tells you to put paths into `syncinclude.txt`. The `--update` argument was removed in 1.6.19 (passing it is an error with a hint).
- To auto-update IFM with this, install `netserver` on the master and set the sync directory to `ifm/`, install `netsync` on the workers, and you can auto-start `netsync` together with `IFMWorker` at boot (via `shell.run` `bg` or `fg`). Whenever IFM updates: install the new version on the master first, then restart `netserver` on the master (its version bumps automatically). Sounds like a hassle? Do it once and benefit forever.

### crafter
- You want IFM auto-crafting, but the vanilla Crafter is slow (and laggy!) — use a turtle as a batch crafter instead.
- Install `crafter.lua` on the turtle and it becomes a batch crafter. You may want a `startup.lua` to launch it automatically (or be lazy and just rename the script to `startup.lua`).
- The turtle needs a crafting table upgrade; a non-crafting turtle cannot craft.
- Once set up, on every redstone pulse the turtle pulls items from the container above it, crafts everything, and pushes the products into the container below (or spits all materials back out if crafting failed).
- Slots 1–9 of the container above map to the crafting grid left-to-right, top-to-bottom — and you can control input slots precisely from IFM.
- The container below is optional; without it the turtle drops the products as items. If there are too many products for the turtle's inventory they are dropped as items as well (e.g. crafting 64× Flint and Steel from 64× Iron Ingot + 64× Flint: the turtle only holds 16, so 48 are dropped).
- Unlike the Crafter (one craft per redstone pulse), the turtle crafts everything in one go. (Or, on older Minecraft versions without the Crafter, this turtle is probably your only option.)
- To control it fully from IFM, put a redstone relay next to the turtle and make the process emit a redstone pulse after all materials have been inserted.
