--------------------------------------------------------------------------------
-- Logstash client for Haskell                                                --
--------------------------------------------------------------------------------
-- This source code is licensed under the MIT license found in the LICENSE    --
-- file in the root directory of this source tree.                            --
--------------------------------------------------------------------------------

-- | A simple Logstash client.
module Logstash (
    runLogstashConn,
    runLogstashPool,
    stash, 
    stashJsonLine, 
    retry
) where 

--------------------------------------------------------------------------------

import Control.Concurrent
import Control.Concurrent.Async
import Control.Monad.Reader
import Control.Monad.Trans.Control

import Data.Aeson
import Data.Acquire
import qualified Data.ByteString.Lazy as BSL
import Data.Either (isRight)
import Data.Pool

import UnliftIO (MonadUnliftIO)

import Logstash.Connection

--------------------------------------------------------------------------------

-- | `stash` @timeout message@ is a computation which sends @message@ to 
-- the Logstash server. If the message is not successfully sent within
-- @timeout@ seconds, the attempt is aborted. The value returned is 
-- `True` if the message was sent successfully.
stash 
    :: MonadIO m 
    => Int
    -> BSL.ByteString 
    -> ReaderT LogstashConnection m Bool
stash secs msg = ask >>= \con -> liftIO $ isRight <$>
    race (threadDelay (secs*1000000)) (writeData con msg) 

-- | `stashJsonLine` @timeout document@ is a computation which serialises
-- @document@ and sends it to the Logstash server. This function is intended
-- to be used with the `json_lines` codec. If sending the JSON takes longer
-- than @timouet@ seconds, the attempt is aborted. The value returned is 
-- `True` if the message was sent successfully.
stashJsonLine 
    :: (MonadIO m, ToJSON a) 
    => Int 
    -> a 
    -> ReaderT LogstashConnection m Bool
stashJsonLine secs = stash secs . (<> "\n") . encode

-- | `retry` @attempts action@ will attempt @action@ up to @attempts@-many
-- times until it returns `True`. If @action@ does not succeed within
-- @attempts@ attempts, `False` is returned.
retry 
    :: Monad m 
    => Int
    -> ReaderT LogstashConnection m Bool 
    -> ReaderT LogstashConnection m Bool
retry n action 
    | n <= 0 = pure False 
    | otherwise = do 
        r <- action 

        if r 
        then pure True 
        else retry (n-1) action

--------------------------------------------------------------------------------

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
    :: MonadBaseControl IO m 
    => Pool LogstashConnection 
    -> ReaderT LogstashConnection m a
    -> m a
runLogstashPool pool action = withResource pool (runReaderT action)

--------------------------------------------------------------------------------
