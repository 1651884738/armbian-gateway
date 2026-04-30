{-# LANGUAGE OverloadedStrings #-}
-- ==============================================================================
-- 【OverloadedStrings 扩展】
-- 在 Haskell 里，双引号包起来的字面量（比如 "hello"）默认严格表示 `String` 类型。
-- （而 `String` 在底层其实是字符的链表 `[Char]`，性能很低）。
-- 开启 OverloadedStrings 后，Haskell 编译器会根据上下文，
-- 自动将 "hello" 转换为高效率的 `Text` 甚至底层的 `ByteString` 类型，极为方便。
-- ==============================================================================

module Gateway.Serial
  ( serialReader  -- 只对外暴露启动串口读取的主函数，内部逻辑都隐藏在这个文件里。
  ) where

-- 控制并发的库
import Control.Concurrent       (threadDelay)
-- STM (Software Transactional Memory) 软件事务内存库，Haskell 处理并发的杀手锏。
import Control.Concurrent.STM   (TChan, TVar, atomically, writeTChan, writeTVar)
-- 异常处理库
import Control.Exception        (SomeException, catch, bracket)
-- Monad 控制流库
import Control.Monad            (forever, unless)
-- Bytestring 处理底层的二进制/字节数据，极其高效。`qualified` 表示使用时必须加上前缀，比如 `BS.empty`，以防函数名冲突。
import qualified Data.ByteString       as BS
import qualified Data.ByteString.Char8 as BS8
import Data.Text                (Text)
import qualified Data.Text.Encoding    as TE
import Data.Time                (getCurrentTime)
-- 我们引入的第三方串口处理库
import System.Hardware.Serialport

import Gateway.Config (SerialConfig(..))
import Gateway.Types  (SensorReading(..))

-- --------------------------------------------------------------------------
-- 波特率映射 (模式匹配 Pattern Matching)
-- --------------------------------------------------------------------------
-- `toBaud` 函数的作用是把普通的整数（比如 9600）转换为 serialport 库要求的特定枚举类型 `CommSpeed`。
-- 这里展示了 Haskell 强大的模式匹配语法：代码会从上到下按顺序检查输入，并执行对应的等式。
toBaud :: Int -> CommSpeed
toBaud 4800   = CS4800
toBaud 9600   = CS9600
toBaud 19200  = CS19200
toBaud 38400  = CS38400
toBaud 57600  = CS57600
toBaud 115200 = CS115200
toBaud _      = CS9600  -- 这里的下划线 `_` 表示“通配符 (Wildcard)”。如果输入不是上面写过的任何数字，就匹配这一条，默认返回 9600。

-- --------------------------------------------------------------------------
-- 串口核心读取逻辑
-- --------------------------------------------------------------------------

-- | 外部调用的入口：打开串口并一直循环读取数据。如果中途串口被拔掉或者报错，它会自动等 5 秒再重连，保证不死机。
-- 这里的参数分别是：
-- 1. `SerialConfig` : 串口配置
-- 2. `TChan SensorReading` : TChan 是 STM 提供的一个并发队列（通道）。我们要把读到的数据塞进去。
-- 3. `TVar Bool` : TVar 也是 STM 提供的事务内存变量，用来在内存里存一个布尔值，代表“当前是否连上了”。
serialReader :: SerialConfig -> TChan SensorReading -> TVar Bool -> IO ()
serialReader cfg chan status = forever $ do  
  -- `forever` 顾名思义，它会把后面紧跟着的 IO 操作放入一个无限死循环中执行。
  -- `$` 符号被称为“应用符”。它的作用是把后面的所有内容计算完，再传给前面的函数。
  -- 它其实是为了替换括号用的。`forever $ do ...` 完全等价于 `forever (do ...)`
  
  -- `<>` 是 Haskell 里通用的连接符（可以拼接 String，Text，ByteString 甚至 List 等）
  putStrLn $ "[Serial] Opening " <> port cfg
  
  -- `catch` 函数用于捕获异常。如果 `withPort cfg chan status` 执行期间崩溃了，
  -- 比如抛出了找不到设备的异常，程序不会闪退，而是会把异常转交给 `onErr` 函数处理。
  catch (withPort cfg chan status) onErr

  -- =========================================================================
  -- 重点：STM (Software Transactional Memory) 无锁并发。
  -- 传统的 C++/Java 写多线程，如果多条线程要修改同一个全局变量（状态），必须加锁 (Mutex)，否则会有竞态条件。
  -- Haskell 引入了数据库事务（Transaction）的概念：
  -- 我们只需要用 `atomically` 声明这是一个原子操作。里面的任何修改，要么完全成功，要么失败重试，绝对不会出现数据撕裂。
  -- =========================================================================
  -- 断开连接后，马上在内存里标记状态为 False。
  atomically $ writeTVar status False
  
  putStrLn "[Serial] Reconnecting in 5 s …"
  threadDelay 5000000 -- Haskell 里的时间单位通常是微秒（Microseconds）。所以 5 百万微秒 = 5 秒。
  
  where
    -- `where` 关键字用于在函数底部定义一些只属于这个函数的局部变量或者局部函数。
    -- 定义异常处理函数：接收一个异常对象 e，打印出来。
    onErr :: SomeException -> IO ()
    onErr e = putStrLn $ "[Serial] Error: " <> show e

-- | 实际打开串口并执行读取的工作逻辑。
withPort :: SerialConfig -> TChan SensorReading -> TVar Bool -> IO ()
withPort cfg chan status =
  -- `bracket` 是 Haskell 里非常重要的“安全资源管理”函数。
  -- 格式：bracket (获取资源) (释放资源) (使用资源)
  -- 比如打开文件、打开数据库、打开串口，中途报错的话很容易导致资源没关闭，产生句柄泄露。
  -- bracket 保证：无论第三步（使用资源）是正常结束还是因为抛出异常中断了，它都一定会去执行第二步（释放资源），相当于 Python 的 with，Java 的 try-with-resources。
  bracket (openSerial (port cfg) settings) closeSerial $ \s -> do
    -- 这里的 `\s -> do` 是 Lambda 匿名函数的写法，反斜杠 `\` 看起来像希腊字母 λ。
    -- `s` 就是第一步 openSerial 成功后返回的代表这个串口的对象。
    
    -- 连接成功，通过 STM 把状态变量设置为 True。
    atomically $ writeTVar status True
    putStrLn "[Serial] Connected"
    
    -- 调用下面定义的递归函数 loop，启动死循环读取串口。初始传入的缓冲数据是空的（BS.empty）。
    loop s BS.empty 
  where
    -- 从配置文件中读取波特率并转换。
    settings = defaultSerialSettings { commSpeed = toBaud (baudRate cfg) }
    
    -- 把串口名（String）打包成底层的 ByteString，然后再解码为现代的 Text 格式。
    src      = TE.decodeUtf8 (BS8.pack (port cfg))

    -- `loop` 函数定义。Haskell 里没有传统的 for 或者 while 循环。
    -- 循环全靠自己调用自己（递归）。因为 Haskell 编译器对这种写在末尾的递归（尾递归）有极强优化，它在底层其实就被翻译成了一个 C 语言里的 goto 跳转循环，不会导致栈溢出。
    loop s buf = do
      chunk <- recv s 256  -- 每次从串口读取最多 256 字节的数据。`<-` 用来提取出包裹在 IO 盒子里的值给 `chunk`。
      
      -- `unless` 就是 `if not` 的简写。如果读到的数据不是空的，就执行后面的逻辑。
      unless (BS.null chunk) $ do 
        -- `let` 关键字用于普通的纯函数计算绑定。注意它和 `<-` 的区别：
        -- `<-` 用在有副作用的上下文（比如从网络读、从硬盘读）。
        -- `let` 用在无副作用纯粹的数学计算（拼接字符串，加减乘除等）。
        let buf' = BS.append buf chunk  -- 把新读到的 256 字节贴到旧数据的尾巴上
            -- 调用 splitFrames 函数，找出所有完整的行（遇到 \n 换行的），并把多余的尾巴剥离出来。
            (frames, rest) = splitFrames buf' 
            
        -- `mapM_` 用于遍历一个列表，并对每个元素执行后面的动作。
        -- 这里把所有提取出来的完整数据行，丢给 `emit` 函数，通过并发管道发射出去。
        mapM_ (emit chan src) frames
        
        -- 继续开启下一轮循环读取！这次带着上面剩下的“半截数据尾巴 (rest)” 一起走。
        loop s rest

-- --------------------------------------------------------------------------
-- 辅助函数
-- --------------------------------------------------------------------------

-- | 按照换行符 \n 将一块连续的数据切分为多条完整行，并返回最后没遇到换行符的部分。
-- 类型签名：输入一个 ByteString，返回一个元组 Tuple (包含多行的列表, 剩余部分)
splitFrames :: BS.ByteString -> ([BS.ByteString], BS.ByteString)
splitFrames bs =
  -- `case ... of` 用于针对不同的情况进行模式匹配处理
  case BS8.split '\n' bs of 
    []  -> ([], BS.empty)    -- 极端情况：切出来是空的，原样返回。
    [x] -> ([], x)           -- 情况 1：切出来只有一个元素，说明里面没有换行符。这完整的一个元素都是未结束的“剩余部分”。
    xs  -> (init xs, last xs) -- 情况 2：切出了多个元素。`init` 函数作用是取出列表中除了最后一个之外的前面所有元素；`last` 函数取出最后一个元素当作剩余部分。

-- | 负责把一条原始数据打包装箱，加上时间戳，放入 STM 并发管道里广播给全程序。
emit :: TChan SensorReading -> Text -> BS.ByteString -> IO ()
emit chan src frame = do
  now <- getCurrentTime  -- 获取系统当前绝对时间
  
  -- 创建一条完整的数据记录。
  let reading = SensorReading
        { readingId     = Nothing  -- 现在它还没落入数据库，所以数据库自增主键目前是不存在的，标记为 Nothing。
        , readingTime   = now
        , readingRaw    = TE.decodeUtf8 frame  -- 把原始字节数据转为合法的字符串。
        , readingSource = src
        }
        
  -- 【无锁并发核心】
  -- writeTChan 操作会把数据写入管道。把它包在 atomically 里面，系统会保证这件事线程绝对安全。
  atomically $ writeTChan chan reading
  
  putStrLn $ "[Serial] Frame: " <> BS8.unpack frame
