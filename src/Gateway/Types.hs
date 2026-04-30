{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
-- ==============================================================================
-- 【语言扩展 (Language Extensions)】
-- Haskell 是一门标准非常严谨的语言（当前大多以 Haskell 2010 为基础）。
-- 但为了使用一些高级或现代的特性，我们需要在文件开头用 `{-# LANGUAGE ... #-}` 来开启。
-- 
-- 1. DeriveGeneric：允许编译器理解我们自定义数据类型的内部构造，从而支持“泛型操作”。
-- 2. DeriveAnyClass：允许我们通过 `deriving` 关键字直接自动实现特定的类（Typeclass），比如 JSON 转换。
-- ==============================================================================

-- ==============================================================================
-- 【模块定义 (Module Declaration)】
-- 每个 Haskell 文件必须以 `module` 开头声明自己的名字。
-- 这里的 `Gateway.Types` 对应于文件路径 `src/Gateway/Types.hs`。
-- 括号 `(...)` 里面是我们要“暴露（Export）”给其他文件使用的内容。
-- 如果不在括号里写明，其他文件即使 import 了这个模块，也无法使用里面的东西。
-- ==============================================================================
module Gateway.Types
  ( SensorReading(..)  -- `(..)` 的意思是：不仅暴露 `SensorReading` 这个类型名称，还要暴露它内部的所有字段（比如 readingId, readingTime 等）。
  , GatewayStatus(..)  -- 同理，暴露 `GatewayStatus` 及其所有内部字段。
  ) where

-- ==============================================================================
-- 【导入区 (Imports)】
-- 导入我们需要用到的外部库和其他模块。
-- ==============================================================================
-- 导入 Aeson 库中用于 JSON 序列化（ToJSON）和反序列化（FromJSON）的类型类。
import Data.Aeson   (ToJSON, FromJSON)

-- 导入标准的 64 位整数类型。Haskell 里的普通 `Int` 大小依赖于系统（通常也是 64 位），但用 `Int64` 更明确。
import Data.Int     (Int64)

-- 导入 `Text` 类型。在现代 Haskell 中，我们处理字符串通常使用 `Text` 而不是默认的 `String`（因为 Text 在内存里紧凑得多，性能更好）。
import Data.Text    (Text)

-- 导入 `UTCTime` 类型，用来表示世界标准时间。
import Data.Time    (UTCTime)

-- 导入泛型支持，配合上面的 DeriveGeneric 使用。
import GHC.Generics (Generic)

-- ==============================================================================
-- 【数据类型定义 (Data Type Definitions)】
-- ==============================================================================

-- | 表示从串口读取到的一条传感器数据。
-- 这里的 `-- |` 是一种特殊的注释语法，称为 Haddock 注释。它可以被工具自动提取生成网页 API 文档。
--
-- `data` 是 Haskell 中定义全新类型的关键字。
-- 第一个 `SensorReading` 是“类型名称”（用在类型签名里）。
-- 等号右边的第二个 `SensorReading` 是“数据构造器名称”（用来在代码里实际创建这个对象）。
-- 这里使用了大括号 `{ ... }`，这叫作“记录语法 (Record Syntax)”，非常适合定义有多个字段的结构体。
data SensorReading = SensorReading
  { -- `::` 读作 "类型为"（is of type）。
    -- `!` (感叹号) 叫作 "严格求值标记 (Strictness Flag)"。Haskell 默认是惰性求值（Lazy）的，加了感叹号意味着在创建这个对象时，必须立刻算出这个字段的值，可以有效防止内存泄漏。
    -- `Maybe` 是一种非常核心的类型，表示“可能存在，也可能不存在”。相当于别的语言里的 Nullable。它只有两个取值：
    -- 1. `Just 值` (例如 `Just 123`)
    -- 2. `Nothing` (表示空)
    readingId     :: !(Maybe Int64) 
    
  , readingTime   :: !UTCTime       -- 记录从串口读到数据时的具体时间。
  
  , readingRaw    :: !Text          -- 记录从串口读到的原始字符串数据。
  
  , readingSource :: !Text          -- 记录数据来源，比如这里可以存 "/dev/ttyUSB0"，方便以后区分多个串口。
  
  } deriving (Show, Generic, ToJSON, FromJSON)
  -- `deriving` 指令是 Haskell 最强功能之一：它能让编译器“自动写代码”。
  -- 1. `Show`: 自动生成将这个数据结构转换为字符串打印出来的代码（比如用 `print` 函数时）。
  -- 2. `Generic`: 自动生成它的泛型表示。
  -- 3. `ToJSON` / `FromJSON`: 让这个结构体立刻拥有被转换为 JSON 以及从 JSON 解析出来的超能力（依赖了 Generic）。

-- | 记录整个网关当前的运行状态，用于 HTTP 接口返回数据给前端。
data GatewayStatus = GatewayStatus
  { serialConnected :: !Bool   -- 串口是否已经连接成功。Bool 只有两个值：True 或者 False。
  , mqttConnected   :: !Bool   -- MQTT 代理是否已经连接成功。
  , totalReadings   :: !Int64  -- 至今一共成功读取并处理了多少条数据。
  , uptimeSeconds   :: !Int    -- 网关程序启动至今一共运行了多少秒。
  } deriving (Show, Generic, ToJSON, FromJSON)
