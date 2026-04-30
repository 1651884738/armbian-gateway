-- ==============================================================================
-- 【主入口模块 (Main Module)】
-- 在 Haskell 里面，生成可执行文件的模块名必须叫做 `Main`，并且里面必须要有一个名为 `main` 的函数。
-- ==============================================================================
module Main where

-- 异步和并发相关的库
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.STM   (newBroadcastTChanIO, newTVarIO, atomically, dupTChan)
import Data.Time                (getCurrentTime)
-- 用来获取终端命令行的参数
import System.Environment       (getArgs)

-- 导入我们自己手写的 5 个内部模块
import Gateway.Config   (loadConfig, serial, mqtt, database, http)
import Gateway.Serial   (serialReader)
import Gateway.MQTT     (mqttPublisher)
import Gateway.Database (initDatabase, dbWriter)
import Gateway.API      (startAPI)

-- | 程序的绝对起点，相当于 C 语言的 `int main()`，类型强制必须是 `IO ()`。
main :: IO ()
main = do
  -- `getArgs` 获取你在终端敲命令时跟在程序名后面的所有参数组成的一个数组。
  -- 比如执行 `cabal run r2s-geteway abc.yaml`，args 就是 `["abc.yaml"]`。
  args <- getArgs
  
  -- 决定使用哪个配置文件。
  -- `case ... of` 对 args 进行模式匹配：
  -- 如果是一个不为空的列表（f 是第一个元素，_ 匹配剩下的），就选用 `f`。
  -- 否则（没给任何参数），默认使用 `"config.yaml"`。
  let cfgFile = case args of
                  (f:_) -> f
                  _     -> "config.yaml"

  -- 打印一条纯文本启动日志
  putStrLn $ "[Main] Loading config: " <> cfgFile
  
  -- --------------------------------------------------------------------------
  -- 阶段 1：初始化资源
  -- --------------------------------------------------------------------------
  
  -- 读取并解析 YAML 配置文件。如果格式错误，程序在这就会直接抛错闪退。
  cfg <- loadConfig cfgFile

  -- 连接并初始化 SQLite 数据库。
  conn <- initDatabase (database cfg)

  -- 建立一个“广播频道（Broadcast TChan）”。
  -- 普通的 Channel 是“单入单出”，读走就没了。
  -- 但广播频道特别适合“一处产生，多处消费”的场景！
  -- 因为我们要让串口不断把数据塞进通道里，同时让 MQTT 和 Database 两个线程各自拿一份独立的数据拷贝。
  broadcastChan <- newBroadcastTChanIO

  -- 创建两个全局的共享变量（TVar）。它们存在内存里，不需要加锁（STM系统会自动处理），用来存储各组件的死活状态。
  serialStatus <- newTVarIO False
  mqttStatus   <- newTVarIO False
  
  -- 记录当前启动时间，用来计算 Uptime（运行了多久）。
  startTime    <- getCurrentTime

  -- --------------------------------------------------------------------------
  -- 阶段 2：准备通道
  -- --------------------------------------------------------------------------

  -- 给两个消费者各自开一个通道分身。
  -- `dupTChan` 的作用是：一旦原版频道里进了新数据，所有的 dup 分身都会同步得到一份一样的数据。互不干扰。
  mqttChan <- atomically $ dupTChan broadcastChan
  dbChan   <- atomically $ dupTChan broadcastChan

  putStrLn "[Main] Starting gateway …"

  -- --------------------------------------------------------------------------
  -- 阶段 3：多线程并发起飞！(withAsync)
  -- --------------------------------------------------------------------------
  -- 如果用底层的 `forkIO` 开启线程，主程序死了子线程可能还活着，会变成僵尸线程乱跑。
  -- `withAsync` 是一种极其优雅、安全的多线程模型。
  -- 它接受两个参数：第一部分是在后台跑的任务；第二部分是一段回调函数代码。
  -- 它保证：只要离开第二部分的作用域，后台任务哪怕正在疯狂运转也会被立刻干净地杀掉！
  
  -- 开辟线程 1：永远不断地读取串口，把数据塞进 broadcastChan
  withAsync (serialReader  (serial cfg) broadcastChan serialStatus) $ \_ ->
    
    -- 开辟线程 2：永远不断地从属于它的 mqttChan 拿数据往网上发
    withAsync (mqttPublisher (mqtt cfg)   mqttChan     mqttStatus)  $ \_ ->
      
      -- 开辟线程 3：永远不断地从属于它的 dbChan 拿数据往 SQLite 里写
      withAsync (dbWriter conn dbChan)                              $ \_ ->
        
        -- 剩下的主线程干嘛？用来启动 HTTP 服务器。
        -- `startAPI` 是一个无尽循环（阻塞方法），只要它在跑，上面的三个异步子线程就会跟它一起永远跑下去！
        -- 如果你按下 Ctrl+C 杀死了主线程的 HTTP 服务器，所有的 withAsync 都会感应到并触发链式死亡，瞬间干净退出，不会有任何内存泄露或僵尸线程。
        startAPI (http cfg) conn serialStatus mqttStatus startTime
