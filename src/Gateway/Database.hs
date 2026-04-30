{-# LANGUAGE OverloadedStrings #-}
-- OPTIONS_GHC -Wno-orphans 意思是：在编译时忽略孤儿实例（Orphan instance）警告。
-- 所谓孤儿实例，就是说当你给一个数据类型（SensorReading）写它的 Typeclass 实例（FromRow/ToRow）时，
-- 规范要求这段代码要么写在定义 SensorReading 的地方，要么写在定义 FromRow 库的地方。
-- 我们写在了第三方的 Database 文件里，编译器会警告。但这对项目结构有好处（数据库相关的代码全放数据库文件），所以我们选择无视警告。
{-# OPTIONS_GHC -Wno-orphans #-}

module Gateway.Database
  ( initDatabase
  , dbWriter
  , queryReadings
  , queryLatest
  , countReadings
  ) where

import Control.Concurrent.STM  (TChan, atomically, readTChan)
import Control.Monad            (forever)
import Data.Int                 (Int64)
import Data.Time                (UTCTime)
-- 导入简单易用的 SQLite 封装库
import Database.SQLite.Simple

import Gateway.Config (DbConfig(..))
import Gateway.Types  (SensorReading(..))

-- --------------------------------------------------------------------------
-- 数据库行映射 (Row Mapping)
-- --------------------------------------------------------------------------

-- `FromRow` 是一种 Typeclass。一旦我们用 `instance FromRow SensorReading where ...` 定义了它，
-- SQLite 库就知道在执行 `SELECT` 捞数据时，如何把捞出来的几个字段依次塞给 `SensorReading` 对象。

instance FromRow SensorReading where
  -- 这一行看起来像魔法，其实是 Applicative Functor 的组合。
  -- `SensorReading` 构造器接收 4 个参数（对应 id, time, raw, source）。
  -- `field` 函数会自动根据当前位置，从数据库行里抓取一个值出来。
  -- `<$>` (fmap) 和 `<*>` (ap) 的组合能把这四个 `field` 抓出来的值安全、依次地塞给 `SensorReading`，完成完美映射！
  fromRow = SensorReading <$> field <*> field <*> field <*> field

-- `ToRow` 则是相反的。当我们往数据库里执行 `INSERT` 时，怎么把对象拆解成一个元组（Tuple）发给数据库。
instance ToRow SensorReading where
  -- 我们只需要传入时间和两串数据。没有传入 id，因为 id 字段在数据库里配置为了 `AUTOINCREMENT`（自增主键）。
  toRow r = toRow (readingTime r, readingRaw r, readingSource r)

-- --------------------------------------------------------------------------
-- 数据库初始化
-- --------------------------------------------------------------------------

-- | 打开（或者创建）SQLite 数据库，并且自动建立相应的表格。
-- 只有在程序的开头才会调用一次。
initDatabase :: DbConfig -> IO Connection
initDatabase cfg = do
  -- `open` 函数会建立或者直接打开该路径下的 db 文件（如果文件不存在，SQLite 会自动新建它）。
  conn <- open (dbPath cfg)  
  
  -- `execute_` (带下划线表示不用传参数进去替换问号)。
  -- 这是一个建表语句，如果表已经存在（IF NOT EXISTS）它就什么都不做，非常适合每次程序启动时执行来保底。
  execute_ conn
    "CREATE TABLE IF NOT EXISTS readings ( \
    \  id        INTEGER PRIMARY KEY AUTOINCREMENT, \
    \  timestamp TEXT    NOT NULL, \
    \  raw_data  TEXT    NOT NULL, \
    \  source    TEXT    NOT NULL  \
    \)"
  putStrLn $ "[DB] Initialized: " <> dbPath cfg
  
  -- 返回那个代表数据库连接的 `conn` 对象给后续代码使用
  return conn

-- --------------------------------------------------------------------------
-- 数据库写入线程 (异步消费者)
-- --------------------------------------------------------------------------

-- | 这是一个独立的消费者多线程函数。
-- 它卡在一个死循环里，从 TChan 通道里读取数据，每读出一条，就存进 SQLite 里。
dbWriter :: Connection -> TChan SensorReading -> IO ()
dbWriter conn chan = forever $ do
  -- 这行代码如果通道没数据就会把当前线程安全挂起休眠（与 MQTT 里的机制一模一样）
  reading <- atomically $ readTChan chan
  
  -- `execute` 是带参数的安全写入函数。
  -- "?" 占位符可以有效防止 SQL 注入。这里直接把 reading 对象扔进去当做第二个参数，
  -- 因为我们在文件上面为它写了 `ToRow` 的实例，SQLite 库内部会找那个实例，把 reading 拆解成 3 个元素填入这三个问号里。
  execute conn
    "INSERT INTO readings (timestamp, raw_data, source) VALUES (?, ?, ?)"
    reading
    
  putStrLn $ "[DB] Saved @ " <> show (readingTime reading)

-- --------------------------------------------------------------------------
-- 数据库查询函数 (主要供给给外层的 HTTP API 接口模块调用)
-- --------------------------------------------------------------------------

-- | 按时间范围和条数限制查询历史数据
-- 它接受 4 个参数：数据库连接，可能有也可能没有的起始时间 mFrom，可能有也可能没有的终止时间 mTo，以及数量限制 mLimit。
-- 返回结果是包裹在 IO 里的数组 `IO [SensorReading]`
queryReadings :: Connection -> Maybe UTCTime -> Maybe UTCTime -> Maybe Int -> IO [SensorReading]
queryReadings conn mFrom mTo mLimit = do
  -- `maybe` 函数很巧妙：`maybe 默认值 应用函数 可能为空的值`
  -- 如果 mLimit 是 Nothing，就返回 100。如果是 Just 50，就取出 50 (通过 `id` 函数，也就是啥也不变地返回)。
  let lim = maybe 100 id mLimit
  
  -- `case` 根据用户有没有提供 from 和 to 参数组合，执行不同结构的 SQL 语句。
  case (mFrom, mTo) of
    (Just f, Just t) ->
      -- 如果 f 和 t 都有，意味着我们要夹在两个时间中间。所以 SQL 带有 `>= ? AND <= ?`
      query conn
        "SELECT id, timestamp, raw_data, source FROM readings \
        \WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp DESC LIMIT ?"
        (f, t, lim)
        
    (Just f, Nothing) ->
      -- 如果只有起始时间，没有终止时间。
      query conn
        "SELECT id, timestamp, raw_data, source FROM readings \
        \WHERE timestamp >= ? ORDER BY timestamp DESC LIMIT ?"
        (f, lim)
        
    (Nothing, Just t) ->
      -- 如果只有截止时间。
      query conn
        "SELECT id, timestamp, raw_data, source FROM readings \
        \WHERE timestamp <= ? ORDER BY timestamp DESC LIMIT ?"
        (t, lim)
        
    (Nothing, Nothing) ->
      -- 两端的时间都不限制，直接取最新的 n 条即可。
      query conn
        "SELECT id, timestamp, raw_data, source FROM readings \
        \ORDER BY timestamp DESC LIMIT ?"
        (Only lim)  -- 重要细节：在 sqlite-simple 里，如果你只有一个参数替换问号，你必须给它包裹上一个 `Only` 构造器。因为如果不包，Haskell 不知道这是一个元组还是普通的括号！

-- | 只查询数据库里最新的一条数据。返回 `Maybe SensorReading`（因为数据库可能是空的，查不出数据返回 Nothing）
queryLatest :: Connection -> IO (Maybe SensorReading)
queryLatest conn = do
  -- `query_` 用于不带任何参数问号的纯净查询
  rows <- query_ conn
    "SELECT id, timestamp, raw_data, source FROM readings \
    \ORDER BY timestamp DESC LIMIT 1"
    
  case rows of
    (r:_) -> return (Just r)  -- `(r:_)` 列表模式匹配：匹配到头部第一个元素叫 r，后面的下划线表示不在乎剩下有什么。我们把它装进 Just 里返回。
    []    -> return Nothing   -- 如果查出来是一个空列表 `[]`，说明库里压根没数据，安全返回 Nothing。

-- | 统计数据库里面总共存在多少条数据记录
countReadings :: Connection -> IO Int64
countReadings conn = do
  -- 这行利用了强制的模式匹配赋值：查询 `COUNT(*)` 一定只会返回一行一列的数据。
  -- 这一列被包裹在 `Only` 里。我们直接在左边写 `[Only n]`，它就会把真实数字拆解出来赋给 `n`。
  [Only n] <- query_ conn "SELECT COUNT(*) FROM readings"
  return n
