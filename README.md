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
- 一个 Minecraft **CC:Tweaked** 脚本。通过定义流程进行自动合成，就像AE2、Integrated Dynamics、或者说Super Factory Manager那样。设定好一切后，只需要点击合成目标产物，就可以看着各种材料经过你的机器，逐步合成并呈递你的目标产物。
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
- **主控与从节点的版本必须完全一致**：版本号对不上时，两边互相拒绝执行搬运/查询（主控不派活、从节点拒绝执行并在屏幕上提示），网页上的从节点卡片也会标红。升级时把所有计算机一起升到同一版本。

## 网页终端
- 浏览器打开[这个页面](https://log4jerr.github.io/CC-IFM/frontend/)，这就是网页终端。
- 你需要在网页终端输入房间号以连接到你游戏内的IFM系统。

## 能做什么
- **库存浏览**：浏览存储的所有物品/流体、支持排序、搜索（支持拼音搜素）。
- **发货**：设定好一个容器作为输出容器，然后你可以指定物品/流体以及数量，将它们移动至输出容器。
- **存储优化**：自动在存储容器之间合并，交换物品，从而腾出空间。这个整理算法会基于槽位容量和物品堆叠数进行合理的移动，让数量多的物品移动到大容量槽位（比如抽屉）。
- **卸货**：设定一个容器作为输入容器，然后里面的物品会被自动取走并放入存储容器。
- **通用自动合成**：这一部分是最复杂的，不能一句话说清楚，看下面的段落

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
- 浏览器与服务端通过 **itty-sockets** 中转的 WebSocket 互相传递消息
- 前端图标和资源信息按照三个方案获取：本地 `frontend/icon-exports/` 导出（质量最佳，但是需要根据Minecraft示例专门导出）→ blocksitems.com 接口（质量很好，不过有些物品缺失，并且不支持国际化）→ 注册名转换（没有图标。你可以按右上角翻译按钮启用Bergamot翻译器以获取你的语言的物品名称，质量较差）。
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
- 主控的数据文件放在安装目录下的 `ifm/data/` 里，从节点自身不保存数据。

## 限制
- 计算机所在区块必须保持加载，否则脚本会停摆（记得准备区块加载手段）。
- 外设在有线线缆上最多传递256格，所以不要让线缆超过这个长度，不然找不到外设。
- 公共中继 `wss://itty.ws/c/` 在部分地区可能连不上，可以自建 itty-sockets 服务器并用 `--relay` 指过去。
- 读容器是阻塞调用（每个容器每次读取约1Tick），容器很多时扫描会变慢，可以调大扫描间隔，或者添加更多从节点。

## 小工具
- backend/tools下是一些其他的CC脚本，提供一些用得着的功能。这些脚本各自独立运行。

### netsync
- 你有1个主控和一大堆从节点，现在IFM版本更新了，一个个去更新可太麻烦了。工具脚本netserver和netsync是成对使用的，用于自动同步文件。
- netserver和netsync启动时需要指定name，相同的name之间的netserver会把文件同步给netsync。
- netserver脚本同目录下两个配置文件决定要同步哪些内容：`syncinclude.txt` 每行一个要同步的路径（目录末尾写 `/`，会递归同步目录下的内容），`syncignore.txt` 每行一个要忽略的路径；两者都支持绝对路径（以 `/` 开头）与相对路径（相对 netserver 脚本所在目录），`#` 开头是注释、空行忽略
- netsync以脚本自身所在目录作为根目录写文件。
- netserver需要两个配置文件，syncinclude.txt和syncignore.txt，前者指定要同步的文件或目录的路径（目录路径末尾加斜杠/），后者指定要排除的路径。
- netsync只会在netserver有更新的版本时才下载。否则会保持等待。
- 每次你更新了文件，需要同步时，使用netserver --update name启动netserver，以更新版本。
- --update参数可以不加，此时netserver不会更新版本。一句话描述：如果你修改了要同步的文件，启动netserver时加--update。如果文件没有变动，不加--update参数。
- 为了使用这个脚本自动更新IFM，你应当在主控节点安装netserver，设置同步目录为ifm/，在从节点安装netsync，并且从节点可以设置netsync和IFMWorker同时开机自启（借助shell.run bg或者fg命令）。每次需要更新IFM版本时，先在主控安装新版IFM，然后在主控运行netserver --update <名称>。觉得太麻烦了？一次处理，之后就可以一直受益。

### crafter
- 现在你希望使用IFM自动合成，可Minecraft原版的合成器速度很慢（而且，很卡！），为此你可以使用海龟合成。
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
- A Minecraft **CC:Tweaked** script. It auto-crafts through *process definitions*, much like AE2, Integrated Dynamics or Super Factory Manager. Once everything is set up you just click the target product and watch materials flow through your machines, being crafted step by step until the requested items show up.
- The same factory can be browsed and managed from a web browser, with no Minecraft client needed.

## Requirements
- CC:Tweaked installed on the Minecraft server. (Needless to say, IFM runs on a CC:Tweaked computer.)
- A correct network topology: you must connect every part of the factory with cable. Concretely, every computer / storage container (chest, barrel, drawers or other storage from other mods, any fluid tank) / machine must be attached to a **wired modem** (wireless will not do; CC:Tweaked ships both cased and full-block wired modems, either works), and all wired modems must be joined with networking cable.
- At least one computer in the whole IFM system. Item/fluid scheduling is expensive, so add as many computers as you like to speed it up. IFM is distributed: one computer is the **master** (`IFMMaster`), the others are **workers** (`IFMWorker`). Running without workers is possible but not recommended unless you can live with snail speed.

## Installation
- Run this single command on **every** computer of the IFM network:
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
- **Master and workers must run exactly the same version**: when the version strings differ they refuse to run moves/queries for each other (the master stops dispatching, the worker refuses and prints a hint, and the worker card is flagged in the web UI). Update every computer together.

## Web terminal
- Open [this page](https://log4jerr.github.io/CC-IFM/frontend/) in your browser - that is the web terminal.
- Enter the room name in the web terminal to connect to your in-game IFM system.

For development you can also serve the frontend locally: `cd frontend` then `python serve.py` (opens http://localhost:8000/index.html).

## Features
- **Stock browsing**: browse all stored items/fluids, with sorting and search (pinyin search supported).
- **Delivery**: mark a container as an output container, then pick items/fluids and amounts to move them there.
- **Storage optimisation**: automatically merges and swaps items between storage containers to free space. The algorithm moves stacks according to slot capacity and stack size, e.g. moving large amounts into high-capacity slots (drawers).
- **Unloading**: mark a container as an input container; anything inside it is taken out and moved into storage automatically.
- **General-purpose auto-crafting**: the most complex part - it cannot be described in one sentence, see the next section.

## Auto-crafting system
- Just like AE2 patterns, IFM auto-crafting needs **machine** and **process** definitions.
- First create a **machine type**. That abstraction layer exists so machines can work in parallel (if you own several brewing stands that can all brew, create and name a machine type such as "Brewing" and let IFM use your stands).
- Next create a **machine** under that machine type; a machine is the smallest working unit. It needs input container(s), output container(s) and an optional redstone signal (IFM can use a redstone relay to send or wait for signals, which is handy at times). For the brewing stand example, add the stand both as input and output container (you insert materials into it and pull products straight out of it). Some machines have several input/output containers (e.g. Create's Mechanical Arm assembly needs materials inserted into both the arm and the depot below it - mark both as input containers).
- Machines have a few more parameters, e.g. **parallel signals** is how many crafting jobs the machine accepts at the same time. The default 1 means the machine must have inserted a job and fully extracted its products before new materials may be inserted. Some machines handle several jobs at once - e.g. a hopper feeding a composter can accept multiple stacks, so raise the value there. (AE2 players will recognise this as a Pattern Provider set to "block until products return".)
- One machine type can contain many machines; when crafting with that type, any idle machine of that type can be used.
- Next create a **process**: the complete set of steps that performs one craft on a machine. Say we want 3x Awkward Potion from 1x Nether Wart + 3x Water Bottle - make that a process. For the potion example, link the process to the brewing machine and set the inserted materials (1x Nether Wart + 3x Water Bottle) and the extracted products (3x Awkward Potion). When a machine has several input/output containers and you need to control which container receives the materials, set the **machine index**; when you need to control which slot inside that container receives them, set the **slot index**. (Most Minecraft logistics/autocrafting mods cannot do slot-precise I/O at all.)
- Product extraction is smart: IFM only extracts the items you specify and ignores everything else. So the brewing example needs no redstone gating like vanilla auto-brewing - and you can be even more precise about which container and which slot to extract from.
- A process runs simply: materials are inserted in order, then products are extracted in order. If materials cannot be inserted, the process waits until they can; if products cannot be extracted, it also waits until they can.
- Processes also have a **max multiplier**: to craft more than one item, IFM multiplies the input materials by that factor, inserts them together and expects the multiplied products. For example, to craft Snow Blocks in the vanilla Crafter (1x Snowball into slots 1..4 -> 1x Snow Block), set the multiplier to 16 (snowballs stack to 16 in the crafter).
- Besides item/fluid I/O, processes support other steps: a timed wait holds the process for at least that long when reached in order; redstone steps need a redstone relay and can wait for a signal or emit one. (Obviously you can encode a process that plays redstone music.)
- **Ignore NBT**: you can ignore item NBT (off by default, which requires NBT to match exactly).
- Products' **minimum** and **maximum** counts target chance-based recipes whose output amount is uncertain. Distribution counts are computed from the maximum (IFM optimistically assumes it can get all products, and retries to craft the remainder if it cannot), and product extraction also uses the maximum (so it never over-extracts). The minimum is used to decide whether an extraction is complete, i.e. the worst case.

## How it works
- Browser and script exchange messages over a WebSocket relayed by **itty-sockets**.
- Icons and resource info are fetched in three fallback tiers: local `frontend/icon-exports/` export (best quality, but must be exported from your own Minecraft instance) -> blocksitems.com API (good quality, but some items are missing and it is not internationalised) -> registry name conversion (no icon; press the translate button top-right to enable the **Bergamot** translator and get item names in your own language, lower quality).
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
- The master's data files live in `ifm/data/` inside the install directory; workers keep no data of their own.

## Limitations
- The chunk the computer is in must stay loaded, otherwise the script stalls (get a chunk loader).
- Peripherals travel at most 256 blocks over wired cable, so do not exceed that length or they cannot be found.
- The public relay `wss://itty.ws/c/` cannot be reached in some regions; host your own itty-sockets server and point to it with `--relay`.
- Container reads are blocking (each container read takes about 1 tick), so large factories scan slowly - raise the scan intervals or add more workers.

## Tools
- `backend/tools/` holds a few extra CC scripts that provide some handy utilities. Each of them runs standalone.

### netsync
- You have one master and a pile of workers, and IFM just released a new version - updating them one by one is a pain. The `netserver` and `netsync` scripts are used as a pair to sync files automatically.
- `netserver` and `netsync` are started with a name; a `netserver` syncs its files to the `netsync`s with the same name.
- Two config files next to the `netserver` script decide what gets synced: `syncinclude.txt` (one path per line to sync; a directory ends with `/` and its contents are synced recursively) and `syncignore.txt` (one path per line to ignore). Both accept absolute paths (leading `/`) and relative paths (relative to the directory of the `netserver` script); lines starting with `#` are comments, empty lines are ignored.
- `netsync` writes files with its own script directory as the root.
- `netserver` needs the two config files, `syncinclude.txt` and `syncignore.txt`: the former lists the files or directories to sync (a directory path ends with `/`), the latter lists the paths to exclude.
- `netsync` only downloads when `netserver` has a newer version; otherwise it keeps waiting.
- Every time you change files and want them synced, start `netserver` with `netserver --update name` to bump the version.
- `--update` may be omitted, in which case `netserver` does not bump the version. In one sentence: add `--update` when the files to sync changed, omit it when they did not.
- To auto-update IFM with this, install `netserver` on the master and set the sync directory to `ifm/`, install `netsync` on the workers, and you can auto-start `netsync` together with `IFMWorker` at boot (via `shell.run` `bg` or `fg`). Whenever IFM updates: install the new version on the master first, then run `netserver --update <name>` on the master. Sounds like a hassle? Do it once and benefit forever.

### crafter
- You want IFM auto-crafting, but the vanilla Crafter is slow (and laggy!) — use a turtle as a batch crafter instead.
- Install `crafter.lua` on the turtle and it becomes a batch crafter. You may want a `startup.lua` to launch it automatically (or be lazy and just rename the script to `startup.lua`).
- The turtle needs a crafting table upgrade; a non-crafting turtle cannot craft.
- Once set up, on every redstone pulse the turtle pulls items from the container above it, crafts everything, and pushes the products into the container below (or spits all materials back out if crafting failed).
- Slots 1–9 of the container above map to the crafting grid left-to-right, top-to-bottom — and you can control input slots precisely from IFM.
- The container below is optional; without it the turtle drops the products as items. If there are too many products for the turtle's inventory they are dropped as items as well (e.g. crafting 64× Flint and Steel from 64× Iron Ingot + 64× Flint: the turtle only holds 16, so 48 are dropped).
- Unlike the Crafter (one craft per redstone pulse), the turtle crafts everything in one go. (Or, on older Minecraft versions without the Crafter, this turtle is probably your only option.)
- To control it fully from IFM, put a redstone relay next to the turtle and make the process emit a redstone pulse after all materials have been inserted.
