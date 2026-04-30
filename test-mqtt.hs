{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Concurrent       (threadDelay)
import Control.Monad            (forever, void)
import qualified Data.ByteString.Char8 as BCS
import qualified Data.ByteString.Lazy  as BL
import qualified Data.Text             as T
import qualified Data.Text.Encoding    as TE
import Data.Conduit.Network     (clientSettings, runTCPClient, appSource, appSink)
import Data.Maybe               (fromMaybe)
import Network.MQTT.Client
import Network.MQTT.Topic       (mkFilter, unTopic)

-- ============================================================
-- 阿里云 IoT 凭据
-- ============================================================
mqttHost :: String
mqttHost = "gaq2dx6XevM.iot-as-mqtt.cn-shanghai.aliyuncs.com"

mqttPort :: Int
mqttPort = 1883

mqttClientId :: String
mqttClientId = "haskell_001|securemode=3,signmethod=hmacmd5|"

mqttUsername :: String
mqttUsername = "haskell_001&gaq2dx6XevM"

mqttPassword :: String
mqttPassword = "915C14B9D4C9EE8F5E4C852F2CBE763E"

mqttSubTopic :: T.Text
mqttSubTopic = "/broadcast/gaq2dx6XevM/data"

-- ============================================================
-- 收到消息时的回调
-- ============================================================
onMsg :: MQTTClient -> Topic -> BL.ByteString -> [Property] -> IO ()
onMsg _mc tp body _props = do
  let topicStr = T.unpack (unTopic tp)
  putStrLn $ "\n[收到消息] Topic: " <> topicStr
  case TE.decodeUtf8' (BL.toStrict body) of
    Right txt -> putStrLn $ "  内容: " <> T.unpack txt
    Left  _   -> putStrLn $ "  (二进制数据, " <> show (BL.length body) <> " bytes)"

-- ============================================================
-- 主程序
-- ============================================================
main :: IO ()
main = do
  putStrLn "=============================="
  putStrLn " MQTT 连接测试"
  putStrLn "=============================="
  putStrLn $ "Host:     " <> mqttHost
  putStrLn $ "Port:     " <> show mqttPort
  putStrLn $ "ClientID: " <> mqttClientId
  putStrLn $ "Username: " <> mqttUsername
  putStrLn ""

  -- 关键发现：connectURI 会从 URI fragment 提取 _connID 覆盖 config，
  -- 且不做 URI 解码。阿里云 clientId 含有 | 字符无法正确传递。
  --
  -- 解决方案：直接使用 runMQTTConduit（底层 API），
  -- 它使用 MQTTConfig 中的字段原样构建 CONNECT 包，不做任何覆盖。
  let cfg = mqttConfig
        { _connID    = mqttClientId
        , _username  = Just mqttUsername
        , _password  = Just mqttPassword
        , _hostname  = mqttHost
        , _port      = mqttPort
        , _protocol  = Protocol311
        , _msgCB     = SimpleCallback onMsg
        }

  -- 使用 runMQTTConduit + runTCPClient 直接建立 TCP 连接
  -- 这样所有 MQTTConfig 字段原样使用，不会被 URI 解析覆盖
  let mkConn f = runTCPClient (clientSettings mqttPort (BCS.pack mqttHost))
                              (\ad -> f (appSource ad, appSink ad))

  putStrLn "[测试] -- 正在连接..."
  mc <- runMQTTConduit mkConn cfg

  putStrLn "[测试] -- 连接成功！"

  let subF = fromMaybe (error "Bad topic") (mkFilter mqttSubTopic)
  _ <- subscribe mc [(subF, subOptions)] []
  putStrLn $ "[测试] 已订阅: " <> T.unpack mqttSubTopic
  putStrLn ""
  putStrLn "[测试] 等待消息中... (按 Ctrl+C 退出)"

  forever $ threadDelay 1000000