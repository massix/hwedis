{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Network.Server (
  Environment,
  MutableIndex,
  RedisConnection,
  serverApp',
  runServerStack,
  findNextIndex,
) where

-----------------------------------------------------

import Control.Concurrent.STM (TArray, TVar, writeTVar)
import Control.Exception (Exception)
import Control.Monad (forever)
import Control.Monad.Trans (MonadIO, MonadTrans, lift, liftIO)
import Control.Monad.Trans.Maybe (MaybeT (runMaybeT))
import Control.Monad.Trans.Reader (ReaderT (runReaderT), ask)
import Data.Array (Array, assocs)
import Data.Array.IArray (listArray)
import Data.Array.MArray (getElems, writeArray)
import qualified Data.ByteString as B
import Data.Foldable (traverse_)
import qualified Data.Messages as M
import qualified Database.Redis as R
import GHC.Conc (atomically, readTVarIO)
import qualified Katip as K
import qualified Network.Client as C
import qualified Network.Redis as RT
import qualified Network.WebSockets as WS

-----------------------------------------------------

-- | The Environment we're using is just a list of connected clients
type Environment = TArray Int C.Client

-- | Get a reference to the next usable index of the array of clients
type MutableIndex = TVar Int

-- | Connection to Redis, created initially by the main but it can be modified by the heartbeat thread
type RedisConnection = TVar R.Connection

-- | The ServerContext will contain the Environment, a Mutable index and the Connection to Redis
type ServerContext = (Environment, MutableIndex, RedisConnection)

data InternalExceptions
  = ClientDisconnected
  deriving (Show)

instance Exception InternalExceptions

-- | Server Monad where everything will be running
newtype ServerM m a = ServerM {unServerM :: ReaderT ServerContext m a}
  deriving (Functor, Applicative, Monad, MonadTrans, MonadIO)

-- | This is what defines a Server Monad
type ServerStack a = ServerM (ReaderT ServerContext (K.KatipT IO)) a

-- | Run a ServerM monad within a given ServerContext
runServerM :: ServerContext -> ServerM m a -> m a
runServerM c m = runReaderT (unServerM m) c

liftKatip :: K.KatipT IO a -> ServerStack a
liftKatip = lift . lift

-- | Run a server stack (the full Monad stack)
runServerStack :: K.LogEnv -> ServerContext -> ServerStack a -> IO a
runServerStack le c m = do
  let readerT = runServerM c m
      katipT = runReaderT readerT c
  K.runKatipT le katipT

getServerContext :: ServerStack ServerContext
getServerContext = lift ask

-- | Main entry point for the Websocket server
serverApp' :: WS.PendingConnection -> ServerStack ()
serverApp' pc = do
  liftKatip $ K.logMsg "hwedis" K.InfoS "New connection incoming"
  client <- liftIO $ runMaybeT (C.mkClient pc)

  -- Needed for forking threads
  env@(environment, index, _) <- getServerContext
  logEnv <- liftKatip K.getLogEnv

  case client of
    Just c@(C.Client ua conn) -> do
      currentIndex <- liftIO $ readTVarIO index
      liftKatip $ K.logMsg "serverApp" K.InfoS $ K.ls $ "Accepted new client, user agent: " ++ ua
      liftIO $ atomically $ writeArray environment currentIndex c

      clients <- liftIO $ atomically $ getElems environment
      liftIO $ atomically $ writeTVar index $ findNextIndex $ listArray (0, 255) clients

      liftIO $ WS.withPingThread conn 30 (pure ()) (runServerStack logEnv env (talk conn currentIndex))
    Nothing -> liftKatip $ K.logMsg "serverApp" K.ErrorS "Client refused"
 where
  talk :: WS.Connection -> Int -> ServerStack ()
  talk conn idx = forever $ do
    msg <- liftIO $ WS.receive conn
    (environment, _, _) <- getServerContext

    case msg of
      WS.ControlMessage (WS.Close _ bs) -> do
        liftKatip $ K.logMsg "talk" K.DebugS "Received close message"
        liftIO $ WS.sendClose conn bs

        -- Remove the client from the array
        liftIO $ atomically $ writeArray environment idx (C.Client "undefined" undefined)
        pure mempty
      -- \^ Stops the thread
      WS.ControlMessage (WS.Ping content) -> do
        liftKatip $ K.logMsg "talk" K.DebugS $ K.ls $ "Received ping message: " ++ show content
        liftIO $ WS.send conn (WS.ControlMessage (WS.Pong content))
      WS.ControlMessage (WS.Pong content) -> do
        liftKatip $ K.logMsg "talk" K.DebugS $ K.ls $ "Received pong message: " ++ show content
      WS.DataMessage _ _ _ (WS.Text _ _) -> do
        liftKatip $ K.logMsg "talk" K.DebugS "Received text message"
        resp <- handleMessage msg

        if M.isBroadcastable resp
          then do
            broadcast (M.toWsMessage resp)
          else liftIO $ WS.send conn (M.toWsMessage resp)
      WS.DataMessage _ _ _ (WS.Binary _) -> do
        liftKatip $ K.logMsg "talk" K.InfoS "Received binary message"

  handleMessage :: WS.Message -> ServerStack M.Response
  handleMessage m = do
    (_, _, tVarConn) <- getServerContext
    rawConn <- liftIO $ readTVarIO tVarConn
    le <- liftKatip K.getLogEnv
    let parsedMsg = M.fromWsMessage m :: Maybe M.Request
    case parsedMsg of
      Nothing -> pure M.Empty
      Just msg -> case msg of
        M.Get objId -> do
          res <- liftIO $ RT.runRedisT rawConn le $ RT.getHash objId
          either handleRedisTError (\(o, f) -> pure $ M.GetR o f) res
        M.List -> handleListMessage
        M.Create obj fields -> do
          res <- liftIO $ RT.runRedisT rawConn le $ RT.newHash obj fields
          either handleRedisTError (\_ -> pure $ M.CreateR obj) res
        M.Update obj fields -> do
          res <- liftIO $ RT.runRedisT rawConn le $ RT.updateHash obj fields
          either handleRedisTError (\_ -> pure $ M.UpdateR obj) res
        M.Delete obj -> do
          res <- liftIO $ RT.runRedisT rawConn le $ RT.removeHash obj
          either handleRedisTError (\_ -> pure $ M.DeleteR obj) res

  handleRedisTError :: String -> ServerStack M.Response
  handleRedisTError _ = pure M.Empty

  handleListMessage :: ServerStack M.Response
  handleListMessage = do
    (_, _, tVarConn) <- getServerContext
    rawConn <- liftIO $ readTVarIO tVarConn
    le <- liftKatip K.getLogEnv
    res <- liftIO $ RT.runRedisT rawConn le RT.allKeys
    case res of
      Left _ -> pure M.Empty
      Right keys -> do
        objects <- traverse (liftIO . RT.runRedisT rawConn le . RT.getHash) keys
        pure $ M.ListR $ retrieveHashes objects

  retrieveHashes ::
    [Either String (B.ByteString, [(B.ByteString, B.ByteString)])] ->
    [(B.ByteString, [(B.ByteString, B.ByteString)])]
  retrieveHashes [] = []
  retrieveHashes [Left _] = []
  retrieveHashes [Right t] = [t]
  retrieveHashes (Left _ : _) = []
  retrieveHashes (Right t : xs) = [t] <> retrieveHashes xs

  broadcast :: WS.Message -> ServerStack ()
  broadcast msg = do
    (environment, _, _) <- getServerContext
    clients <- liftIO $ atomically $ getElems environment
    let connected = filter ((/= "undefined") . C.getUserAgent') clients
    liftKatip $ K.logMsg "broadcast" K.InfoS $ K.ls $ "Broadcasting to " ++ show (length connected) ++ " clients"
    traverse_ (\c -> liftIO $ WS.send (C.getConnection' c) msg) connected

-- | Given an array of clients, find the next usable index (recycle)
findNextIndex :: Array Int C.Client -> Int
findNextIndex = fst . head . filter ((== "undefined") . C.getUserAgent' . snd) . assocs
