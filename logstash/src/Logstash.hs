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
import Control.Concurrent.Timeout
import Control.Exception
import Control.Monad.Catch (MonadMask)
import Control.Monad.Reader
import Control.Monad.Trans.Control
import Control.Retry

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

-- | A type of exceptions that can occur related to Logstash connections.
data LogstashException = LogstashTimeout
    deriving (Eq, Show) 

instance Exception LogstashException where 
    displayException _ = "Writing to Logstash timed out."

-- | A type class of types that provide Logstash connections.
class LogstashContext ctx where 
    runLogstash 
        :: (MonadMask m, MonadUnliftIO m) 
        => ctx 
        -> RetryPolicyM m
        -> Integer
        -> (RetryStatus -> ReaderT LogstashConnection m a) 
        -> m a

instance LogstashContext (Acquire LogstashConnection) where 
    runLogstash = runLogstashConn

instance LogstashContext LogstashPool where
    runLogstash = runLogstashPool

-- | `runLogstashConn` @connectionAcquire computation@ runs @computation@ using
-- a Logstash connection produced by @connectionAcquire@.
runLogstashConn 
    :: (MonadMask m, MonadUnliftIO m)
    => Acquire LogstashConnection
    -> RetryPolicyM m
    -> Integer 
    -> (RetryStatus -> ReaderT LogstashConnection m a) 
    -> m a 
runLogstashConn acq policy time action = 
    recoverAll policy $ \s -> 
    withRunInIO $ \runInIO -> do 
    -- run the Logstash action with the specified timeout
    mr <- timeout time $ runInIO $ withAcquire acq $ runReaderT (action s)
    
    -- raise an exception if a timeout occurred
    maybe (throw LogstashTimeout) pure mr

-- | `runLogstashPool` @pool computation@ takes a `LogstashConnection` from
-- @pool@ and runs @computation@ with it.
runLogstashPool 
    :: (MonadMask m, MonadUnliftIO m) 
    => Pool LogstashConnection 
    -> RetryPolicyM m
    -> Integer
    -> (RetryStatus -> ReaderT LogstashConnection m a)
    -> m a
runLogstashPool pool policy time action =
    recoverAll policy $ \s -> 
    withRunInIO $ \runInIO -> 
    mask $ \restore -> do
        -- acquire a connection from the resource pool
        (resource, local) <- takeResource pool

        mr <- restore (timeout time $ runInIO $ runReaderT (action s) resource) 
            `onException` destroyResource pool local resource

        -- raise an exception if a timeout occurred
        maybe (throw LogstashTimeout) pure mr

--------------------------------------------------------------------------------
