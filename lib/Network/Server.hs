{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Server (
  Environment,
  MutableIndex,
  serverApp',
  runServerStack,
  findNextIndex,
) where

-----------------------------------------------------

import Network.Client (Client (..), getConnection', getUserAgent', mkClient)
import Control.Concurrent (forkIO, myThreadId, threadDelay, throwTo)
import Control.Concurrent.STM (TArray, TVar, writeTVar)
import Control.Exception (Exception)
import Control.Monad (forever)
import Control.Monad.Trans (MonadIO, MonadTrans, lift, liftIO)
import Control.Monad.Trans.Maybe (MaybeT (runMaybeT))
import Control.Monad.Trans.Reader (ReaderT (runReaderT), ask)
import Data.Array (Array, assocs)
import Data.Array.IArray (listArray)
import Data.Array.MArray (getElems, writeArray)
import Data.Foldable (traverse_)
import GHC.Conc (ThreadId, atomically, readTVarIO)
import Katip (Katip (getLogEnv), KatipT, LogEnv, Severity (ErrorS, InfoS), logMsg, ls, runKatipT)
import Network.WebSockets (Connection, ControlMessage (..), DataMessage (..), Message (..), PendingConnection, receive, send, sendClose, withPingThread)

-----------------------------------------------------

-- | The Environment we're using is just a list of connected clients
type Environment = TArray Int Client

-- | Get a reference to the next usable index of the array of clients
type MutableIndex = TVar Int

-- | The ServerContext will contain both the Environment and a Mutable index
type ServerContext = (Environment, MutableIndex)

data InternalExceptions
  = ClientDisconnected
  deriving (Show)

instance Exception InternalExceptions

-- | Server Monad where everything will be running
newtype ServerM m a = ServerM {unServerM :: ReaderT ServerContext m a}
  deriving (Functor, Applicative, Monad, MonadTrans, MonadIO)

-- | This is what defines a Server Monad
type ServerStack = ServerM (ReaderT ServerContext (KatipT IO))

-- | Run a ServerM monad within a given ServerContext
runServerM :: ServerContext -> ServerM m a -> m a
runServerM c m = runReaderT (unServerM m) c

-- | Run a server stack (the full Monad stack)
runServerStack :: LogEnv -> ServerContext -> ServerStack a -> IO a
runServerStack le c m = do
  let readerT = runServerM c m
      katipT = runReaderT readerT c
  runKatipT le katipT

-- | Main entry point for the Websocket server
serverApp' :: PendingConnection -> ServerStack ()
serverApp' pc = do
  withKatip $ logMsg "hwedis" InfoS "New connection incoming"
  client <- liftIO $ runMaybeT (mkClient pc)

  -- Needed for forking threads
  env <- getServerContext
  logEnv <- withKatip getLogEnv

  index <- getIndex
  environment <- getEnvironment

  case client of
    Just c@(Client ua conn) -> do
      currentIndex <- liftIO $ readTVarIO index
      withKatip $ logMsg "serverApp" InfoS $ ls $ "Accepted new client, user agent: " ++ ua
      liftIO $ atomically $ writeArray environment currentIndex c

      clients <- liftIO $ atomically $ getElems environment
      liftIO $ atomically $ writeTVar index $ findNextIndex $ listArray (0, 255) clients

      -- Fork thread for Redis communication
      threadId <- liftIO $ forkIO $ runServerStack logEnv env forkThread
      liftIO $ withPingThread conn 30 (pure ()) (runServerStack logEnv env (talk conn threadId currentIndex))
    Nothing -> withKatip $ logMsg "serverApp" ErrorS "Client refused"
 where
  withKatip :: KatipT IO a -> ServerStack a
  withKatip = lift . lift

  forkThread :: ServerStack ()
  forkThread = do
    withKatip $ logMsg "fork" InfoS "Forking thread"
    forever $ do
      myId <- liftIO myThreadId
      liftIO $ threadDelay 10_000_000
      withKatip $ logMsg "fork" InfoS (ls $ "Waiting for redis message " ++ show myId)

  getServerContext :: ServerStack ServerContext
  getServerContext = lift ask

  getEnvironment :: ServerStack Environment
  getEnvironment = fst <$> getServerContext

  getIndex :: ServerStack MutableIndex
  getIndex = snd <$> getServerContext

  talk :: Connection -> ThreadId -> Int -> ServerStack ()
  talk conn tid idx = forever $ do
    msg <- liftIO $ receive conn
    environment <- getEnvironment

    case msg of
      ControlMessage (Close _ bs) -> do
        withKatip $ logMsg "talk" InfoS "Received close message"
        liftIO $ sendClose conn bs

        -- Remove the client from the array
        liftIO $ atomically $ writeArray environment idx (Client "undefined" undefined)
        -- Stop the forked thread
        liftIO $ throwTo tid ClientDisconnected
      ControlMessage (Ping content) -> do
        withKatip $ logMsg "talk" InfoS $ ls $ "Received ping message: " ++ show content
        liftIO $ send conn (ControlMessage (Pong content))
      ControlMessage (Pong content) -> do
        withKatip $ logMsg "talk" InfoS $ ls $ "Received pong message: " ++ show content
      DataMessage _ _ _ (Text _ _) -> do
        withKatip $ logMsg "talk" InfoS "Received text message"
        broadcast msg
      DataMessage _ _ _ (Binary _) -> do
        withKatip $ logMsg "talk" InfoS "Received binary message"

  broadcast :: Message -> ServerStack ()
  broadcast msg = do
    environment <- getEnvironment
    clients <- liftIO $ atomically $ getElems environment
    let connected = filter ((/= "undefined") . getUserAgent') clients
    withKatip $ logMsg "broadcast" InfoS $ ls $ "Broadcasting to " ++ show (length connected) ++ " clients"
    traverse_ (\c -> liftIO $ send (getConnection' c) msg) connected

-- | Given an array of clients, find the next usable index (recycle)
findNextIndex :: Array Int Client -> Int
findNextIndex = fst . head . filter ((== "undefined") . getUserAgent' . snd) . assocs
