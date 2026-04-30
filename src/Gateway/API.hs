{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE OverloadedStrings #-}
-- ==============================================================================
-- 【API 相关的语言扩展】
-- Servant 是 Haskell 里最知名的写 HTTP 接口的库，它的原理极度硬核：把整个接口路由规则写在“类型”里面。
-- 为此我们需要开启两个很生僻但极其强大的扩展：
-- 1. DataKinds: 允许把普通的数据（比如字符串 "api"）提升到“类型（Type）”的层面去。
-- 2. TypeOperators: 允许我们在定义类型的时候，使用特殊的符号（比如 `:>` 还有 `:<|>` ）。
-- ==============================================================================

module Gateway.API
  ( startAPI  -- 只需要向外暴露一个启动服务器的入口即可。
  ) where

import Control.Concurrent.STM   (TVar, readTVarIO)
import Control.Monad.IO.Class   (liftIO)
import Data.Int                 (Int64)
import Data.Proxy               (Proxy(..))
import Data.Time                (UTCTime, diffUTCTime, getCurrentTime)
import Database.SQLite.Simple   (Connection)
-- Warp 是 Haskell 里面性能极高（媲美 Nginx）的底层 Web 服务器引擎。
import Network.Wai.Handler.Warp (run)
-- Servant 核心库
import Servant

import Gateway.Config   (HttpConfig(..))
import Gateway.Database (queryReadings, queryLatest, countReadings)
import Gateway.Types    (SensorReading(..), GatewayStatus(..))

-- --------------------------------------------------------------------------
-- API 路由类型定义 (The Servant API Type)
-- --------------------------------------------------------------------------

-- 在这里，我们通过写一长串“类型”，就把三个 API 的 URL、请求方法、带什么参数、返回什么格式，规定得死死的。
-- `:>` 符号读作 "接着是"。它用来拼接 URL 路径，或者用来提取参数。
-- `:<|>` 符号读作 "或者"。用来并列不同的接口。
-- `'[JSON]` 意思是这个接口会把返回的数据自动转换成 JSON 格式（因为它依赖了 Aeson 的 ToJSON）。

type GatewayAPI =
       -- 接口 1: GET /api/readings?from=xxx&to=xxx&limit=xxx
       -- `QueryParam` 表示提取 URL 里 `?xxx=` 的参数。返回结果是 `[SensorReading]` 数组。
       "api" :> "readings"
         :> QueryParam "from"  UTCTime
         :> QueryParam "to"    UTCTime
         :> QueryParam "limit" Int
         :> Get '[JSON] [SensorReading]

  :<|> -- 接口 2: GET /api/readings/latest
       -- 返回的可能是一条数据（Just），也可能没数据（Nothing），所以用 Maybe。
       "api" :> "readings" :> "latest"
         :> Get '[JSON] (Maybe SensorReading)

  :<|> -- 接口 3: GET /api/status
       -- 返回网关的当前系统状态（GatewayStatus 结构体会自动被转成 JSON 字符串返回）。
       "api" :> "status"
         :> Get '[JSON] GatewayStatus

-- --------------------------------------------------------------------------
-- Server 实现层 (The Handlers)
-- --------------------------------------------------------------------------

-- | 定义一个环境容器（Tuple 元组），把数据库连接和那几个代表状态的共享内存变量打包在一起传进来。
type Env = (Connection, TVar Bool, TVar Bool, UTCTime)

-- | `server` 就是专门用来给上面那个 `GatewayAPI` 类型填入真正干活的业务代码的。
-- Servant 会在编译期做极其严苛的检查：这里提供的函数数量、参数类型、返回值类型，必须和上面的路由定义 **严丝合缝**！
-- 这里用 `:<|>` 把三个函数连在一起返回。
server :: Env -> Server GatewayAPI
server (conn, serialSt, mqttSt, startTime) =
       getReadings conn
  :<|> getLatest   conn
  :<|> getStatus   conn serialSt mqttSt startTime

-- | 对应接口 1 的业务代码。
-- 参数依次对应前面定义的 `QueryParam`。如果用户没传那个参数，收到的就是 `Nothing`。
-- 返回类型是 `Handler [SensorReading]`。
getReadings :: Connection -> Maybe UTCTime -> Maybe UTCTime -> Maybe Int -> Handler [SensorReading]
getReadings conn mFrom mTo mLimit =
  -- `queryReadings` 是个普通的 IO 函数，但在 Servant 里面必须返回 `Handler` 类型。
  -- `liftIO` 是一个变魔术的函数，它可以把一个普通的 `IO` 动作“提升(lift)”到 `Handler` 的世界里去执行。
  liftIO $ queryReadings conn mFrom mTo mLimit

-- | 对应接口 2 的业务代码。
getLatest :: Connection -> Handler (Maybe SensorReading)
getLatest conn = liftIO $ queryLatest conn

-- | 对应接口 3 的业务代码。
getStatus :: Connection -> TVar Bool -> TVar Bool -> UTCTime -> Handler GatewayStatus
getStatus conn serialSt mqttSt startTime = liftIO $ do
  -- `readTVarIO` 是用来无锁、快速读取 STM 并发变量当前最新值的函数。
  -- 它不需要包在 atomically 里，因为只读不写，是最快的取值方式。
  s  <- readTVarIO serialSt
  m  <- readTVarIO mqttSt
  
  -- 调用数据库模块查出总数据量
  n  <- countReadings conn
  
  now <- getCurrentTime
  -- `diffUTCTime` 算出当前时间减去启动时间的差值。
  -- `round` 把带有小数的时间差四舍五入成一个整数。`:: Int` 则是强制声明我们要的是个 Int，别给搞错了。
  let up = round (diffUTCTime now startTime) :: Int
  
  -- 组装好 `GatewayStatus` 对象返回。只要返回这个对象，Servant 就会自动在底层帮你转成 JSON 发给浏览器。
  return GatewayStatus
    { serialConnected = s
    , mqttConnected   = m
    , totalReadings   = n
    , uptimeSeconds   = up
    }

-- --------------------------------------------------------------------------
-- 启动入口 (Entry Point)
-- --------------------------------------------------------------------------

-- | 启动 HTTP 服务器。由于它是个网络监听循环，执行这行代码就会卡死（挂起主线程），一直提供服务。
startAPI :: HttpConfig -> Connection -> TVar Bool -> TVar Bool -> UTCTime -> IO ()
startAPI cfg conn serialSt mqttSt startTime = do
  putStrLn $ "[HTTP] Listening on port " <> show (httpPort cfg)
  
  let env = (conn, serialSt, mqttSt, startTime)
  
  -- `run` 是 Warp 引擎的启动命令，参数一是端口号。
  -- `serve` 是 Servant 库的命令，用来把我们的 `server` 业务逻辑变成 Wai 标准的应用，然后丢给 Warp 去跑。
  -- `(Proxy :: Proxy GatewayAPI)` 是告诉编译器：“请根据这段空气代码推导出 API 路由！”，这是高级技巧，照写即可。
  run (httpPort cfg) $ serve (Proxy :: Proxy GatewayAPI) (server env)
