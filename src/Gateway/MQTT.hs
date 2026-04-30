{-# LANGUAGE OverloadedStrings #-}

module Gateway.MQTT
  ( mqttPublisher
  ) where

import Control.Concurrent       (threadDelay)
import Control.Concurrent.STM   (TChan, TVar, atomically, readTChan, writeTVar)
import Control.Exception        (SomeException, catch)
import Control.Monad            (forever)
import qualified Data.Aeson            as Aeson
import qualified Data.ByteString.Char8 as BCS
import qualified Data.ByteString.Lazy  as BL
import Data.Conduit.Network     (clientSettings, runTCPClient, appSource, appSink)
import Data.Maybe               (fromMaybe)
import qualified Data.Text             as T
import qualified Data.Text.Encoding    as TE
-- MQTT 核心库
import Network.MQTT.Client
import Network.MQTT.Topic       (mkTopic, mkFilter, unTopic)
import Network.MQTT.Types       (QoS(..))
import Gateway.Config (MqttConfig(..))
import Gateway.Types  (SensorReading(..))

-- --------------------------------------------------------------------------
-- 核心 MQTT 逻辑（发布 + 订阅）
-- --------------------------------------------------------------------------

-- | 外部调用入口：连接到 MQTT Broker，订阅消息并打印，同时从通道获取数据发布出去。
mqttPublisher :: MqttConfig -> TChan SensorReading -> TVar Bool -> IO ()
mqttPublisher cfg chan status = forever $ do
  putStrLn $ "[MQTT] Connecting to " <> T.unpack (broker cfg) <> ":" <> show (brokerPort cfg)
  catch (runMqtt cfg chan status) onErr
  atomically $ writeTVar status False
  putStrLn "[MQTT] Reconnecting in 5 s …"
  threadDelay 5000000
  where
    onErr :: SomeException -> IO ()
    onErr e = putStrLn $ "[MQTT] Error: " <> show e

-- | 实际进行连接、订阅、发布的工作函数。
runMqtt :: MqttConfig -> TChan SensorReading -> TVar Bool -> IO ()
runMqtt cfg chan status = do
  let hostStr = T.unpack (broker cfg)
      portInt = brokerPort cfg

  let mCfg = mqttConfig
        { _connID    = T.unpack (clientId cfg)
        , _username  = fmap T.unpack (username cfg)
        , _password  = fmap T.unpack (password cfg)
        , _hostname  = hostStr
        , _port      = portInt
        , _protocol  = Protocol311
        , _msgCB     = SimpleCallback onMessage
        }

  putStrLn $ "[MQTT] ClientID: " <> T.unpack (clientId cfg)
  putStrLn $ "[MQTT] Username: " <> show (username cfg)
  
  let mkConn f = runTCPClient (clientSettings portInt (BCS.pack hostStr))
                              (\ad -> f (appSource ad, appSink ad))

  mc <- runMQTTConduit mkConn mCfg
  
  atomically $ writeTVar status True
  putStrLn "[MQTT] Connected!"

  -- ========================================================================
  -- 订阅主题
  -- ========================================================================
  -- subscribe 需要 Filter 类型（和 Topic 不同，Filter 支持 # 和 + 通配符）
  let subFilter = fromMaybe (error "Invalid subscribe topic") (mkFilter (subscribeTopic cfg))
  
  -- subscribe 函数：订阅一个或多个主题。
  -- 参数是一个列表，每个元素是 (Filter, SubOptions) 的元组。
  -- subOptions 是默认的订阅选项。
  _subs <- subscribe mc [(subFilter, subOptions)] []
  putStrLn $ "[MQTT] Subscribed to: " <> T.unpack (subscribeTopic cfg)

  -- 进入发布循环（同时消息接收是在后台线程通过回调自动处理的）
  publishLoop mc cfg chan

-- | 消息接收回调函数。
-- 每当服务器推送一条消息到我们订阅的主题时，net-mqtt 库会自动在后台调用这个函数。
-- 参数说明：
--   _mc    : MQTT 客户端对象（这里用 _ 前缀表示我们暂时不使用它）
--   topic  : 收到消息的具体主题名称
--   body   : 消息体（Lazy ByteString 格式）
--   _props : MQTT 5.0 属性列表（3.1.1 下为空）
onMessage :: MQTTClient -> Topic -> BL.ByteString -> [Property] -> IO ()
onMessage _mc tp body _props = do
  let topicStr = T.unpack (unTopic tp)
      bodyStr  = BL.unpack body
  putStrLn $ "[MQTT] ← Received on [" <> topicStr <> "]:"
  -- 尝试把消息体当 UTF-8 文本打印出来
  case TE.decodeUtf8' (BL.toStrict body) of
    Right txt -> putStrLn $ "  " <> T.unpack txt
    Left  _   -> putStrLn $ "  (binary data, " <> show (BL.length body) <> " bytes)"

-- | 死循环：源源不断地从通道拿数据发送
publishLoop :: MQTTClient -> MqttConfig -> TChan SensorReading -> IO ()
publishLoop mc cfg chan = forever $ do
  reading <- atomically $ readTChan chan
  
  let payload = Aeson.encode reading
      t = fromMaybe (error "Invalid MQTT topic") (mkTopic (topic cfg))
  
  publishq mc t payload False QoS1 []
  putStrLn $ "[MQTT] → Published @ " <> show (readingTime reading)
