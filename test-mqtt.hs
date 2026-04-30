{-# LANGUAGE OverloadedStrings #-}
-- ^ 开启 OverloadedStrings 扩展：允许我们在代码中直接写 "字符串" 来表示 ByteString 或 Text，而不仅仅是 String。

module Main where

-- 【基础控制与并发库】
import Control.Concurrent       (threadDelay)
import Control.Monad            (forever, void)

-- 【数据类型转换库】
-- 在网络编程中，数据通常是字节流 (ByteString)，而我们打印时需要用到文本 (Text) 和普通字符串 (String)
import qualified Data.ByteString.Char8 as BCS  -- 处理 ASCII 字符的字节流
import qualified Data.ByteString.Lazy  as BL   -- 处理大块数据的惰性字节流 (MQTT 消息体使用)
import qualified Data.Text             as T    -- 高效的 Unicode 文本类型
import qualified Data.Text.Encoding    as TE   -- 用于 ByteString 和 Text 之间的编解码

-- 【网络与数据流底层库】
import Data.Conduit.Network     (clientSettings, runTCPClient, appSource, appSink)
import Data.Maybe               (fromMaybe)

-- 【MQTT 客户端库】
import Network.MQTT.Client      -- MQTT 核心 API (如 mqttConfig, subscribe)
import Network.MQTT.Topic       (mkFilter, unTopic) -- MQTT 主题过滤与解析

-- ============================================================
-- 步骤 1: 定义阿里云 IoT 连接凭据
-- ============================================================
-- 注意：实际项目中，这些硬编码的字符串建议从配置文件 (config.yaml) 中读取。

mqttHost :: String
mqttHost = "gaq2dx6XevM.iot-as-mqtt.cn-shanghai.aliyuncs.com"  -- 阿里云设备接入点

mqttPort :: Int
mqttPort = 1883  -- MQTT 默认非加密端口 (如果用 MQTTS 加密通常是 1883 或 443)

-- ClientID (客户端 ID)：阿里云要求包含签名方法等特殊字符（比如 | 符号）
mqttClientId :: String
mqttClientId = "haskell_001|securemode=3,signmethod=hmacmd5|"

mqttUsername :: String
mqttUsername = "haskell_001&gaq2dx6XevM"

mqttPassword :: String
mqttPassword = "915C14B9D4C9EE8F5E4C852F2CBE763E"

-- 我们要订阅的主题 (Topic)，当设备往这个主题发数据时，我们就能收到
mqttSubTopic :: T.Text
mqttSubTopic = "/broadcast/gaq2dx6XevM/data"


-- ============================================================
-- 步骤 2: 定义收到 MQTT 消息时的回调函数 (Callback)
-- ============================================================
-- 每当有消息到达订阅的 Topic 时，底层库会自动调用这个函数。
-- 参数依次为：MQTT 客户端实例, 消息所在的主题, 消息体 (字节流), 附加属性
onMsg :: MQTTClient -> Topic -> BL.ByteString -> [Property] -> IO ()
onMsg _mc tp body _props = do
  -- 1. 将原生的 Topic 类型转换回普通的 String 方便打印
  let topicStr = T.unpack (unTopic tp)
  putStrLn $ "\n[收到消息] Topic: " <> topicStr
  
  -- 2. 尝试将字节流 (ByteString) 解码为 UTF-8 文本 (Text)
  --    TE.decodeUtf8' 可能会失败（比如收到的是纯二进制图片），所以它返回一个 Either 类型
  case TE.decodeUtf8' (BL.toStrict body) of
    Right txt -> 
      -- 如果解码成功，打印出纯文本内容
      putStrLn $ "  内容: " <> T.unpack txt
    Left  _   -> 
      -- 如果解码失败，说明它是不可读的二进制数据，只打印它的大小
      putStrLn $ "  (二进制数据, " <> show (BL.length body) <> " bytes)"


-- ============================================================
-- 步骤 3: 程序入口 (Main)
-- ============================================================
main :: IO ()
main = do
  -- 打印启动信息
  putStrLn "=============================="
  putStrLn " MQTT 连接测试"
  putStrLn "=============================="
  putStrLn $ "Host:     " <> mqttHost
  putStrLn $ "Port:     " <> show mqttPort
  putStrLn $ "ClientID: " <> mqttClientId
  putStrLn $ "Username: " <> mqttUsername
  putStrLn ""

  -- 【构建 MQTT 配置对象 (cfg)】
  -- 关键难点说明：
  -- 通常连接 MQTT 会使用 `connectURI` 函数，但那个函数在解析 URL 时，会把 ClientID 里的 `|` 符号当成非法字符丢掉或报错。
  -- 阿里云的 ClientID 必须包含 `|`，所以我们只能通过手动赋值，构造一个原汁原味的 `MQTTConfig` 对象。
  let cfg = mqttConfig
        { _connID    = mqttClientId               -- 设置客户端 ID
        , _username  = Just mqttUsername          -- 设置用户名 (用 Just 包裹，因为它是可选的 Maybe 类型)
        , _password  = Just mqttPassword          -- 设置密码
        , _hostname  = mqttHost                   -- 设置服务器地址
        , _port      = mqttPort                   -- 设置端口
        , _protocol  = Protocol311                -- 指定使用 MQTT 3.1.1 版本协议
        , _msgCB     = SimpleCallback onMsg       -- 绑定我们上面写好的 onMsg 回调函数，告诉它收到消息去调谁
        }

  -- 【自定义 TCP 连接方法 (mkConn)】
  -- 因为我们抛弃了自带的 URL 解析函数，所以需要自己告诉底层库：如何建立一条 TCP 管道。
  -- runTCPClient 负责底层的 socket 拨号，appSource(代表读通道) 和 appSink(代表写通道) 是这个管道的两个端点。
  let mkConn f = runTCPClient (clientSettings mqttPort (BCS.pack mqttHost))
                              (\ad -> f (appSource ad, appSink ad))

  putStrLn "[测试] -- 正在连接..."
  
  -- 开始连接！
  -- runMQTTConduit 会使用我们提供的 TCP 管道 (mkConn) 和配置参数 (cfg) 去完成 MQTT 的底层握手认证
  mc <- runMQTTConduit mkConn cfg

  putStrLn "[测试] -- 连接成功！"

  -- 【订阅 Topic】
  -- mkFilter 用于将字符串转换为合法的 MQTT 过滤器（它支持解析通配符 # 和 +）
  -- fromMaybe 用于处理：如果给定的主题格式不合法（返回了 Nothing），就直接抛出 error 中断程序
  let subF = fromMaybe (error "Bad topic") (mkFilter mqttSubTopic)
  
  -- subscribe 发送订阅请求。
  -- 返回的 "_ <-" 表示我们执行了这个动作，但是不在乎它的返回值。
  _ <- subscribe mc [(subF, subOptions)] []
  putStrLn $ "[测试] 已订阅: " <> T.unpack mqttSubTopic
  putStrLn ""
  putStrLn "[测试] 等待消息中... (按 Ctrl+C 退出)"

  -- 【保持主线程存活】
  -- 因为接收消息的回调函数 (onMsg) 是在底层新建的另外一个独立线程里运行的。
  -- 如果主线程走到这里结束了，整个程序就会瞬间退出。所以我们用一个死循环 (forever) 让主线程一直休眠 (threadDelay)。
  forever $ threadDelay 1000000  -- 每次休眠 1,000,000 微秒 (即 1 秒)