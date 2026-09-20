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
- 一个 Minecraft CC:Tweaked 脚本。通过定义流程进行自动合成，就像AE2、Integrated Dynamics、或者说Super Factory Manager那样。设置好后，只需要点击合成目标产物，就可以看着各种材料经过你的机器，逐步合成并呈递你的目标产物。
- 如果你不知道那是什么，CC:Tweaked是一个添加了Minecraft内的计算机的mod，支持多种mod加载器和多个版本
- 可以通过浏览器访问并管理你的工厂，而无需打开Minecraft客户端。
- 支持工作台合成，或者通用的外部机器合成（就像AE使用样板供应器那样），无论是熔炉、营火、酿造、堆肥、各种其他模组的机器
- 原生支持对产物的过滤抽取，并且生存造价低廉（你只需要一些黄金、玻璃、石头和红石粉，就可以搭建整个系统）

## 运行环境说明
- Minecraft服务器安装了CC:Tweaked。这是必要的废话，IFM在CC:Tweaked的计算机上运行
- 搭建了正确的网络拓扑结构，你需要使用和线缆将工厂的各个部分连接。具体来说，对于每个 计算机/存储容器（箱子、木桶、或者其他模组提供的抽屉之类，或者各种流体储罐）/机器，需要连接到有线调制解调器(无线的不行，CC:Tweaked提供了片式和块式的两种有线调制解调器，都可以)，并且用线缆连接所有有线调制解调器。
- 在整个IFM系统中，你至少要接入一台计算机，而由于物品/流体调度非常耗时，为了提高运行速度，你可以尽情添加更多的计算机。IFM是分布式的，其中一台计算机作为主控节点（IFMMaster），其余计算机作为受控节点（IFMWorker）。可以在没有IFMWorker的情况下运行，但不推荐，除非你能忍受蜗牛速度。


## 使用
- 参见此项目的[Wiki](https://github.com/Log4jErr/CC-IFM/wiki)

[English](#en) | [中文](#zh)
<a id="en"></a>

# CC-IFM Integrated Factory Manager
## What is it
- A Minecraft CC:Tweaked program. It automates crafting by letting you define processes, much like AE2, Integrated Dynamics or Super Factory Manager. Once set up, you only ask for the target product and watch the materials flow through your machines until it is crafted and delivered.
- If that means nothing to you: CC:Tweaked is a mod that adds in-game computers to Minecraft; it supports several mod loaders and Minecraft versions.
- Manage your factory from a browser - you never have to open the Minecraft client.
- Supports crafting-table crafting as well as generic external machines (the way AE2 uses pattern providers): furnaces, campfires, brewing stands, composters, machines from other mods, ...
- Product extraction is filtered out of the box, and the whole system is cheap to build in survival: some gold, glass, stone and redstone dust are enough.

## Requirements
- A Minecraft server with CC:Tweaked installed. Obviously - IFM runs on CC:Tweaked computers.
- A correct network topology. Connect every part of the factory **with wired modems and cable**: for every computer / storage container (chests, barrels, drawers or fluid tanks from other mods, ...) / machine you need a wired modem (wireless will not do; CC:Tweaked has both the wired modem block and the wired-modem face for computers and turtles - either is fine), and all wired modems have to be joined by networking cable.
- At least one computer in the IFM system. Item/fluid logistics is expensive to run, so add as many computers as you like to make it faster: IFM is distributed - one computer is the master node (IFMMaster) and the rest are worker nodes (IFMWorker). It can run with no IFMWorker at all, but that is not recommended unless you can live with snail speed.

## Usage
- See this project's [Wiki](https://github.com/Log4jErr/CC-IFM/wiki)
