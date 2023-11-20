{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Main where

--------------------------------------------------------------------------------
import Control.Concurrent (threadDelay, forkIO)
import Control.Concurrent.STM (atomically, newTVarIO, writeTVar)
import Control.Exception (SomeException, try, handle)
import Control.Monad.Trans (lift, liftIO)
import Data.Configuration (
  Configuration (..), ConfigurationSource (..),
  readConfiguration,
 )
import qualified Database.Redis as R
import Katip (
  ColorStrategy (..),
  LogEnv,
  Severity (..),
  Verbosity (..),
  defaultScribeSettings,
  initLogEnv,
  logMsg,
  ls,
  mkHandleScribe,
  permitItem,
  registerScribe,
  runKatipT,
 )
import Network.Server (runServerStack, serverApp')
import Network.WebSockets (runServer)
import System.IO (stdout)
import qualified Data.Time.Clock.Duration as D
import Network.Redis (runRedisT, pingRedis, RedisT)
import Control.Monad (forever)
import Control.Monad.Except (MonadError(catchError))
import Control.Concurrent.STM.TVar (TVar)

--------------------------------------------------------------------------------

type ThreadDelay = Int
type MaxAttempts = Int
type CurrentAttempt = Int

main :: IO ()
main = do
  -- Init TVar and TArray
  clients <- newTVarIO []

  -- Init KatipT
  handleScribe <- mkHandleScribe ColorIfTerminal stdout (permitItem InfoS) V1
  le <- initLogEnv "hwedis" "production" >>= registerScribe "stdout" handleScribe defaultScribeSettings

  -- Read Configuration from file
  conf <- readConfiguration (FromFile "hwedis.toml")

  -- This will block until Redis isn't connected
  connRaw <- tryConnect le (connectInfo conf) 0 10
  conn <- newTVarIO connRaw

  runKatipT le $ logMsg "main" InfoS "Initializing server"

  -- On a separate thread, check the connection with Redis and reconnect if necessary
  _ <- forkIO $ forever $ do
    handle (handleConnectionLost conf le conn) $
      runRedisT connRaw le $ do
        catchError pingRedis (handleRedisDisconnected conf le conn)
        liftIO $ threadDelay [D.µs| 10s|]

  -- Launch the server
  runServer (getWebserverHost conf) (getWebserverPort conf)
    $ \pc -> runServerStack le (clients, conn) $ do
      lift $ lift $ logMsg "main" DebugS "Starting webserver"
      serverApp' pc

 where
  connectInfo :: Configuration -> R.ConnectInfo
  connectInfo conf = R.defaultConnectInfo{R.connectHost = getRedisHost conf, R.connectPort = toPortNumber $ getRedisPort conf}

  handleConnectionLost :: Configuration -> LogEnv -> TVar R.Connection -> SomeException -> IO (Either String ())
  handleConnectionLost conf le conn exc = do
    runKatipT le $ logMsg "main" ErrorS $ ls ("Connection lost: " <> show exc)
    newConn <- tryConnect le (connectInfo conf) 0 10
    atomically $ writeTVar conn newConn
    pure $ Right ()


  handleRedisDisconnected :: Configuration -> LogEnv -> TVar R.Connection -> String -> RedisT ()
  handleRedisDisconnected conf le tVar e = do
    runKatipT le $ logMsg "main" ErrorS $ ls ("Failed to ping redis: " <> show e)
    connRaw <- liftIO $ tryConnect le (connectInfo conf) 0 10
    liftIO $ atomically $ writeTVar tVar connRaw

toPortNumber :: Int -> R.PortID
toPortNumber = R.PortNumber . fromIntegral

tryConnect :: LogEnv -> R.ConnectInfo -> ThreadDelay -> MaxAttempts -> IO R.Connection
tryConnect le ci dl ma = do
  runKatipT le $ logMsg "main" InfoS $ ls ("Trying to connect to Redis: " <> show ci)
  tryConnect' 0 dl
 where
  tryConnect' :: CurrentAttempt -> ThreadDelay -> IO R.Connection
  tryConnect' ca ldl
    | ca > ma = do
        runKatipT le $ logMsg "main" ErrorS "Failed to connect to Redis, exiting shamefully"
        error "Redis is not responding"

    | otherwise = do
        threadDelay ldl
        conn <- try $ R.checkedConnect ci :: IO (Either SomeException R.Connection)
        case conn of
          Left err -> do
            runKatipT le
              $ logMsg "main" WarningS
              $ ls ("Could not connect to Redis: " <> show err <> " - Retrying...")

            let newDuration = [D.µs| 5s|] :: Int
            tryConnect' (ca + 1) (ldl + newDuration)
          Right c -> do
            runKatipT le $ logMsg "main" InfoS "Connected!"
            pure c
