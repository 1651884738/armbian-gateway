{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
-- 解释见 Types.hs：用于开启泛型支持和自动推导类型类（Typeclasses）。

module Gateway.Config
  ( GatewayConfig(..)
  , SerialConfig(..)
  , MqttConfig(..)
  , DbConfig(..)
  , HttpConfig(..)
  , loadConfig  -- 除了暴露类型，也暴露了我们写的 loadConfig 函数，用于让 Main.hs 调用。
  ) where

import Data.Text    (Text)
import Data.Yaml    (FromJSON, decodeFileThrow)
import GHC.Generics (Generic)

-- ==============================================================================
-- 【配置文件结构体定义】
-- 这些类型直接映射了 `config.yaml` 文件的层级结构。
-- 借助于 `FromJSON`，YAML 库可以把 YAML 文件里的键值对自动"填充"到这些字段里。
-- 注意：`::` 后面跟的永远是**类型**（比如 Text, Int, Bool），不是具体的值！
-- 具体的值写在 config.yaml 里面。
-- ==============================================================================

-- | 这是总的配置对象，包含了四个子配置模块。
data GatewayConfig = GatewayConfig
  { serial   :: !SerialConfig  -- 对应 YAML 里的 "serial:" 块
  , mqtt     :: !MqttConfig    -- 对应 YAML 里的 "mqtt:" 块
  , database :: !DbConfig      -- 对应 YAML 里的 "database:" 块
  , http     :: !HttpConfig    -- 对应 YAML 里的 "http:" 块
  } deriving (Show, Generic, FromJSON)

-- | 串口相关的配置项
data SerialConfig = SerialConfig
  { port     :: !FilePath  -- FilePath 在 Haskell 里并不是一个特殊的类型，它其实只是 String 的类型别名（Type Synonym）。
  , baudRate :: !Int       -- 串口波特率，例如 9600
  } deriving (Show, Generic, FromJSON)

-- | MQTT 相关的配置项
-- 阿里云 IoT 需要的参数：broker 地址、端口号、clientId、username、password
data MqttConfig = MqttConfig
  { broker         :: !Text        -- MQTT 服务器地址（主机名），例如 "xxx.iot-as-mqtt.cn-shanghai.aliyuncs.com"
  , brokerPort     :: !Int         -- MQTT 服务器端口号，阿里云通常是 1883（非 TLS）或 443（TLS）
  , clientId       :: !Text        -- 客户端 ID（阿里云格式：deviceName|securemode=3,signmethod=hmacmd5|）
  , topic          :: !Text        -- 要发布的主题（Topic）
  , subscribeTopic :: !Text        -- 要订阅接收消息的主题（可以用 # 或 + 通配符）
  , username       :: !(Maybe Text) -- 用户名（阿里云格式：deviceName&productKey）
  , password       :: !(Maybe Text) -- 密码（阿里云用 HMAC-MD5 签名算出的值）
  } deriving (Show, Generic, FromJSON)

-- | SQLite 数据库相关的配置
data DbConfig = DbConfig
  { dbPath :: !FilePath      -- SQLite 数据库文件的保存路径，比如 "gateway.db"
  } deriving (Show, Generic, FromJSON)

-- | HTTP 接口相关的配置
data HttpConfig = HttpConfig
  { httpPort :: !Int         -- HTTP 服务器监听的端口号，比如 8080
  } deriving (Show, Generic, FromJSON)

-- ==============================================================================
-- 【配置加载函数】
-- ==============================================================================

-- | 从 YAML 文件加载配置。
loadConfig :: FilePath -> IO GatewayConfig
loadConfig = decodeFileThrow
