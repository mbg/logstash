--------------------------------------------------------------------------------
-- Logstash client for Haskell                                                --
--------------------------------------------------------------------------------
-- This source code is licensed under the MIT license found in the LICENSE    --
-- file in the root directory of this source tree.                            --
--------------------------------------------------------------------------------

-- | A simple Logstash client.
module Logstash (
    module Logstash.Connection,
    
    -- * Running Logstash actions
    LogstashContext(..),
    runLogstashConn,
    runLogstashPool,

    -- * Codecs
    stash, 
    stashJsonLine
) where 

--------------------------------------------------------------------------------

import Control.Concurrent
import Control.Concurrent.Async
import Control.Exception
import Control.Monad.Reader
import Control.Monad.Trans.Control

import Data.Aeson
import Data.Acquire
import qualified Data.ByteString.Lazy as BSL
import Data.Either (isRight)
import Data.Pool

import UnliftIO (MonadUnliftIO(..))

import Logstash.Connection

--------------------------------------------------------------------------------

-- | `stash` @timeout message@ is a computation which sends @message@ to 
-- the Logstash server. If the message is not successfully sent within
-- @timeout@ seconds, the attempt is aborted. The value returned is 
-- `True` if the message was sent successfully.
stash 
    :: MonadIO m 
    => BSL.ByteString 
    -> ReaderT LogstashConnection m ()
stash msg = ask >>= \con -> liftIO $ writeData con msg

-- | `stashJsonLine` @timeout document@ is a computation which serialises
-- @document@ and sends it to the Logstash server. This function is intended
-- to be used with the `json_lines` codec. If sending the JSON takes longer
-- than @timouet@ seconds, the attempt is aborted. The value returned is 
-- `True` if the message was sent successfully.
stashJsonLine 
    :: (MonadIO m, ToJSON a) 
    => a 
    -> ReaderT LogstashConnection m ()
stashJsonLine = stash . (<> "\n") . encode

--------------------------------------------------------------------------------

-- | A type class of types that provide Logstash connections.
class LogstashContext ctx where 
    runLogstash 
        :: MonadUnliftIO m 
        => ctx 
        -> ReaderT LogstashConnection m a 
        -> m a

instance LogstashContext (Acquire LogstashConnection) where 
    runLogstash = runLogstashConn

instance LogstashContext LogstashPool where
    runLogstash = runLogstashPool

-- | `runLogstashConn` @connectionAcquire computation@ runs @computation@ using
-- a Logstash connection produced by @connectionAcquire@.
runLogstashConn 
    :: MonadUnliftIO m 
    => Acquire LogstashConnection 
    -> ReaderT LogstashConnection m a 
    -> m a 
runLogstashConn acq action = withAcquire acq (runReaderT action)

-- | `runLogstashPool` @pool computation@ takes a `LogstashConnection` from
-- @pool@ and runs @computation@ with it.
runLogstashPool 
    :: MonadUnliftIO m 
    => Pool LogstashConnection 
    -> ReaderT LogstashConnection m a
    -> m a
runLogstashPool pool action = 
    withRunInIO $ \runInIO -> 
    mask $ \restore -> do
        (resource, local) <- takeResource pool
        r <- restore (runInIO $ runReaderT action resource) `onException` 
                destroyResource pool local resource
        pure r

--------------------------------------------------------------------------------
