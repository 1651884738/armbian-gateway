# R2S 物联网网关 (Haskell)

本项目是一个基于 Haskell 的物联网网关程序，设计用于连接 R2S (Rockchip RK3328) 设备硬件与阿里云 IoT 平台。它具备串口通信、本地 SQLite 数据库存储、HTTP API 提供以及 MQTT 消息订阅和发布等核心功能。

## 主要功能

*   **串口通信 (Serial)**: 读取 `/dev/ttyUSB0` 等串口设备传来的传感器数据（例如温湿度、能耗等），并解析为内部数据结构。
*   **阿里云 IoT 接入 (MQTT)**: 
    *   通过 MQTT 协议 (v3.1.1) 与阿里云 IoT 平台建立安全连接。
    *   处理复杂的阿里云 `ClientID` 验证机制（如 HMAC-MD5 签名校验）。
    *   自动订阅云端下发的命令或广播消息，并将本地传感器数据发布至云端。
*   **本地存储 (SQLite)**: 自动将读取到的传感器数据以及网关系统状态（CPU温度、运行时间等）存入本地 SQLite 数据库（`gateway.db`），保障数据持久化和断网续传能力。
*   **HTTP API 接口**: 提供轻量级的 RESTful API（默认端口 `8080`），方便本地局域网其他设备或调试工具查询网关实时状态和历史数据。
*   **并发架构**: 采用 Haskell 的 STM (Software Transactional Memory) 和 Async 机制，各子系统（串口、MQTT、API）在独立线程中运行，通过 TChan/TVar 进行安全高效的异步通信与状态共享。

## 项目结构

```text
src/
├── Gateway/
│   ├── API.hs          # HTTP API 路由与处理逻辑 (Servant)
│   ├── Config.hs       # 配置文件加载与解析 (YAML)
│   ├── Database.hs     # SQLite 数据库初始化与操作封装
│   ├── MQTT.hs         # 阿里云 MQTT 连接、订阅与发布实现 (net-mqtt, conduit)
│   ├── Serial.hs       # 串口数据采集解析 (serialport)
│   └── Types.hs        # 核心数据类型与 JSON 实例定义
app/
└── Main.hs             # 网关主程序入口，协调各个子系统启动
test-mqtt.hs            # 独立的 MQTT 连接测试与调试工具
config.yaml             # 系统主配置文件
config-test.yaml        # 用于测试环境的配置文件
```

## 构建与运行

### 环境要求

*   [GHC](https://www.haskell.org/ghc/) (>= 9.6.7)
*   [Cabal](https://www.haskell.org/cabal/) (>= 3.10)
*   本地需要有串口设备的读取权限（如果在 Linux 下开发，通常需要将用户加入 `dialout` 组）

### 编译项目

在项目根目录下运行：

```bash
cabal build
```

### 运行网关

编译完成后，可以通过以下命令启动网关服务：

```bash
cabal run r2s-geteway
```

网关启动后，将会依次初始化配置、数据库、串口监听、MQTT 客户端及 HTTP 服务器。

### 运行 MQTT 连接测试

由于阿里云 IoT 的连接鉴权要求较为特殊（`ClientID` 包含特殊字符和签名参数），本项目内置了一个专门的 MQTT 连通性测试程序。可以通过以下命令单独运行它：

```bash
cabal run test-mqtt
```

## 配置说明

网关通过 `config.yaml` 进行配置，主要包含以下部分：

```yaml
mqtt:
  broker: "你的阿里云IoT产品Broker地址"
  brokerPort: 1883
  clientId: "设备ID|securemode=3,signmethod=hmacmd5|"
  topic: "/发布的主题"
  subscribeTopic: "/订阅的主题"
  username: "用户名&产品Key"
  password: "设备密钥的HMAC签名"

serial:
  device: "/dev/ttyUSB0"
  baudRate: 115200
```

## 技术栈选型

*   **HTTP 框架**: `servant-server`, `warp`
*   **MQTT 客户端**: `net-mqtt`, `conduit-extra`
*   **数据库**: `sqlite-simple`
*   **串口操作**: `serialport`
*   **并发控制**: `async`, `stm`
*   **JSON/配置处理**: `aeson`, `yaml`

## 许可证

MIT License
