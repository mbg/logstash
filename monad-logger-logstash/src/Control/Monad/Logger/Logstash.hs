--------------------------------------------------------------------------------
-- Logstash backend for monad-logger                                          --
--------------------------------------------------------------------------------
-- This source code is licensed under the MIT license found in the LICENSE    --
-- file in the root directory of this source tree.                            --
--------------------------------------------------------------------------------

-- | This module implements `runLogstashLoggerT` which can be
-- used to write log messages that arise in a `LoggingT` computation to a
-- given `LogstashContext`. The following example demonstrates how to use the 
-- `runLogstashLoggerT` function with a TCP connection to Logstash, the
-- default retry policy from `Control.Retry`, a 1s timeout for each attempt,
-- and the @json_lines@ codec:
-- 
-- > main :: IO ()
-- > main = do 
-- >    let ctx = logstashTcp def
-- >    runLogstashLoggerT ctx retryPolicyDefault 1000000 (const stashJsonLine) $ 
-- >         logInfoN "Hello World"
--
-- Assuming a suitable Logstash server that can receive this message,
-- something like the following JSON document should be indexed (see the 
-- documentation for `Control.Monad.Logger` for information about how to include
-- more information in log messages):
--
-- > { 
-- >    "@version":"1",
-- >    "message":"Hello World",
-- >    "log.origin.file.line":0,
-- >    "log.origin.file.module":"<unknown>",
-- >    "log.origin.file.package":"<unknown>",
-- >    "log.origin.file.start.column":0,
-- >    "log.origin.file.start.line":0,
-- >    "log.origin.file.end.column":0,
-- >    "log.origin.file.end.line":0,
-- >    "log.origin.file.name":"<unknown>",
-- >    "log.logger":"",
-- >    "log.level":"info"
-- > }
--
-- If an error or a timeout occurs while writing to the Logstash connection,
-- the retry policy determines whether and when sending the message is
-- attempted again. If all attempts fail, the most recent exception is thrown
-- to the caller.
module Control.Monad.Logger.Logstash (
    runLogstashLoggerT,
    stashJsonLine,

    withLogstashLoggerT,

    -- * Re-exports
    LogstashContext(..)
) where 

--------------------------------------------------------------------------------

import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.STM.TBMQueue
import Control.Exception (Handler)
import Control.Monad
import Control.Monad.Logger
import Control.Monad.Trans.Reader
import Control.Retry

import Data.Aeson
import Data.Maybe
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)

import UnliftIO (MonadUnliftIO)

import Logstash hiding (stashJsonLine)
import qualified Logstash as L (stashJsonLine)

--------------------------------------------------------------------------------

-- | `runLogstashLoggerT` @context retryPolicy time codec logger@ runs a 
-- `LoggingT` computation which writes all log entries to the Logstash 
-- @context@ using the given @codec@. The @retryPolicy@ determines whether 
-- and how the handler should deal with failures that arise. Each attempt
-- that is made by the @retryPolicy@ will have a timeout of @time@
-- microseconds applied to it. 
runLogstashLoggerT 
    :: LogstashContext ctx 
    => ctx 
    -> RetryPolicyM IO
    -> Integer
    -> ( RetryStatus -> 
         (Loc, LogSource, LogLevel, LogStr) -> 
         ReaderT LogstashConnection IO ()
       )
    -> LoggingT m a 
    -> m a
runLogstashLoggerT ctx policy time codec log = runLoggingT log $ 
    \logLoc logSource logLevel logStr -> runLogstash ctx policy time $ 
    \s -> codec s (logLoc, logSource, logLevel, logStr)

-- | `withLogstashLoggerT` @cfg codec exceptionHandlers logger@ is like
-- `withLogstashQueue` except for `LoggingT` computations so that log messages
-- are automatically added to the queue.
withLogstashLoggerT
    :: (LogstashContext ctx, MonadUnliftIO m)
    => LogstashQueueCfg ctx
    -> ( RetryStatus -> 
         (Loc, LogSource, LogLevel, LogStr) ->
         ReaderT LogstashConnection IO ()
       )
    -> [(Loc, LogSource, LogLevel, LogStr) -> Handler ()]
    -> LoggingT m a
    -> m a
withLogstashLoggerT cfg dispatch hs log = withLogstashQueue cfg dispatch hs $ 
    \queue -> runLoggingT log $
    \logLoc logSource logLevel logStr -> atomically $ 
        writeTBMQueue queue (logLoc, logSource, logLevel, logStr)

--------------------------------------------------------------------------------

-- | `stashJsonLine` @entry@ serialises @entry@ as JSON using reasonable
-- defaults for Elasticsearch based on 
-- https://www.elastic.co/guide/en/ecs/current/ecs-field-reference.html
-- and sends the result to Logstash using the @json_lines@ codec.
stashJsonLine :: (Loc, LogSource, LogLevel, LogStr) 
              -> ReaderT LogstashConnection IO ()
stashJsonLine (logEntryLoc, logEntrySource, logEntryLevel, logEntryMessage) = 
    L.stashJsonLine $ object 
    [ "message" .= decodeUtf8 (fromLogStr logEntryMessage)
    , "log" .= object 
        [ "logger" .= logEntrySource
        , "level" .= jsonLogLevel logEntryLevel
        , "origin" .= object 
            [ "file" .= object 
                [ "name" .= loc_filename logEntryLoc 
                , "line" .= fst (loc_start logEntryLoc)
                -- the following fields are not part of the ECS
                , "package" .= loc_package logEntryLoc
                , "module" .= loc_module logEntryLoc
                , "start" .= jsonCharPos (loc_start logEntryLoc)
                , "end" .= jsonCharPos (loc_end logEntryLoc)
                ] 
            ]
        ]
    ]
    where jsonLogLevel :: LogLevel -> Text
          jsonLogLevel LevelDebug = "debug"
          jsonLogLevel LevelInfo = "info"
          jsonLogLevel LevelWarn = "warn"
          jsonLogLevel LevelError = "error"
          jsonLogLevel (LevelOther x) = x

          jsonCharPos :: (Int, Int) -> Value
          jsonCharPos (line, column) =
              object [ "line" .= line, "column" .= column ]

--------------------------------------------------------------------------------
