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
## 警告
```
尽管已经可用，此项目仍在开发阶段，使用过程中可能遇见各种奇怪的问题。
```

## 这是什么
- 一个 Minecraft CC:Tweaked 脚本。通过定义流程进行自动合成，就像AE2、Integrated Dynamics、或者说Super Factory Manager那样。设置好后，只需要点击合成目标产物，就可以看着各种材料经过你的机器，逐步合成并呈递你的目标产物。
- 如果你不知道那是什么，CC:Tweaked是一个添加了Minecraft内的计算机的mod，支持多种mod加载器和多个版本
- 可以通过浏览器访问并管理你的工厂，而无需打开Minecraft客户端。
- 支持工作台合成，或者通用的外部机器合成（就像AE使用样板供应器那样），无论是熔炉、营火、酿造、堆肥、各种其他模组的机器
- 原生支持对产物的过滤抽取，并且生存造价低廉（你只需要一些黄金、玻璃、石头和红石粉，就可以搭建整个系统）

## 运行环境说明
- Minecraft服务器安装了CC:Tweaked，无其他依赖。

## 使用
- 参见此项目的[Wiki](https://github.com/Log4jErr/CC-IFM/wiki)

## 自建中转（WebSocket + HTTP，可选 TLS）
`tools/relay/` 下是一个**通用广播中转**：纯 JDK 标准库实现，产物是单个跨平台 jar（Windows / Linux / macOS，只需 JRE 11+）。它同时提供两种通道，**同一房间内两种通道互通**（网页用 WebSocket，主控也可以用 HTTP）：

- **WebSocket**：`ws://<主机>:<端口>/c/<房间>`（升级连接、双向推送）
- **HTTP**：`GET /c/<房间>?uid=<自己的uid>&wait=<毫秒>` 拉取帧，`POST /c/<房间>?uid=<自己的uid>`（请求体即一帧）发布；发送者同样收不到自己的帧

```
java -jar tools/relay/ws-relay.jar -P 8765                     # 明文：ws:// + http://
java -jar tools/relay/ws-relay.jar -P 8765 --tls-port 8766 \
     --tls-keystore relay.p12 --tls-password changeit          # 额外 TLS：wss:// + https://
```

- 证书也可用 PEM：`--tls-cert cert.pem --tls-key key8.pem`（私钥需 PKCS#8）；自签证书生成：
  `keytool -genkeypair -alias relay -keyalg RSA -keysize 2048 -storetype PKCS12 -keystore relay.p12 -storepass changeit -dname CN=localhost`
  （浏览器首次访问 wss:// 需手动信任该证书）
- 房间 = URL 最后一段（`/c/abc` 即房间 `abc`）；`http://<主机>:<端口>/` 看各房间在线人数，`--help` 列出全部参数
- 指向 IFM：网页“中转地址”填 `ws://` 或 `wss://` 地址；主控**按协议名自动切换传输**：
  `IFMMaster.lua --room <房间> --relay ws://<主机>:8765/c/`（换成 `wss://` / `http://` / `https://` 同一地址即可）
  —— 走 http(s) 时需要该计算机开启 http API（CC:Tweaked 配置 `http.enabled`）
- 自检：`java -jar tools/relay/ws-relay.jar --selftest`（校验 WS 转发、HTTP 拉取/发布、跨通道互通；加上 `--tls-cert/--tls-key` 则同时校验 wss）
- 改源码后自行编译（文件名带连字符，顶层类不是 public，`java -jar` 照样能跑）：

```
cd tools/relay
javac --release 11 -encoding UTF-8 -d build ws-relay.java
jar --create --file ws-relay.jar --main-class WsRelay -C build .
```

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
- A Minecraft server with CC:Tweaked installed. 

## Usage
- See this project's [Wiki](https://github.com/Log4jErr/CC-IFM/wiki)

## Self-hosted relay (WebSocket + HTTP, TLS optional)
`tools/relay/` holds a **generic broadcast relay**: JDK standard library only, shipped as one cross-platform jar (Windows / Linux / macOS, JRE 11+). It serves two carriers at once and **both share the same rooms** (the page can use WebSocket while the master uses HTTP):

- **WebSocket**: `ws://<host>:<port>/c/<room>` (upgraded connection, both directions)
- **HTTP**: `GET /c/<room>?uid=<own uid>&wait=<ms>` polls the queued frames, `POST /c/<room>?uid=<own uid>` (the body is one frame) publishes; a sender never gets its own frame back

```
java -jar tools/relay/ws-relay.jar -P 8765                     # plain: ws:// + http://
java -jar tools/relay/ws-relay.jar -P 8765 --tls-port 8766 \
     --tls-keystore relay.p12 --tls-password changeit          # plus TLS: wss:// + https://
```

- certificates can also be a PEM pair: `--tls-cert cert.pem --tls-key key8.pem` (the key has to be PKCS#8); make a self signed one with
  `keytool -genkeypair -alias relay -keyalg RSA -keysize 2048 -storetype PKCS12 -keystore relay.p12 -storepass changeit -dname CN=localhost`
  (the browser has to trust that certificate once before wss:// works)
- the room is the last url path segment (`/c/abc` is room `abc`); `http://<host>:<port>/` lists the rooms and their client counts; `--help` shows every option
- pointing IFM at it: the page's relay field takes a `ws://` or `wss://` url, and the master **picks the transport from the scheme**:
  `IFMMaster.lua --room <room> --relay ws://<host>:8765/c/` (the same url with `wss://`, `http://` or `https://` also works)
  - the http(s) transports need the http API on that computer (CC:Tweaked `http.enabled`)
- check it: `java -jar tools/relay/ws-relay.jar --selftest` (websocket forwarding, http poll/publish, cross-carrier bridging; add the `--tls-cert/--tls-key` options to check wss as well)
- rebuild it after changing the source (the file name has a hyphen, so the top level class is not public - `java -jar` runs it all the same):

```
cd tools/relay
javac --release 11 -encoding UTF-8 -d build ws-relay.java
jar --create --file ws-relay.jar --main-class WsRelay -C build .
```
