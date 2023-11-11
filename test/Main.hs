{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Main where

--------------------

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM (atomically, newTVarIO)
import qualified Control.Concurrent.Thread as T
import Control.Monad.Reader (MonadReader (ask), ReaderT (runReaderT))
import Control.Monad.Trans (lift)
import Data.Array.IArray (listArray)
import Data.Array.MArray (MArray (newArray))
import Data.Configuration (
  Configuration (getWebserverHost, getWebserverPort),
  ConfigurationSource (..),
  getConfiguration,
  getRedisHost,
  getRedisPort,
  readConfiguration,
  runConfigurationM,
 )
import qualified Data.Time.Clock.Duration as D
import Katip (
  ColorStrategy (..),
  KatipT,
  LogEnv,
  Severity (..),
  Verbosity (..),
  defaultScribeSettings,
  initLogEnv,
  logMsg,
  mkHandleScribe,
  permitItem,
  registerScribe,
  runKatipT,
 )
import Network.Client (Client (Client), Header (Header), extractUserAgent, key, value)
import Network.Server (Environment, MutableIndex, findNextIndex, runServerStack, serverApp')
import Network.WebSockets (
  Connection,
  ControlMessage (..),
  DataMessage (..),
  Message (..),
  defaultConnectionOptions,
  receive,
  runClientWith,
  runServer,
  send,
 )
import RedisTest
import System.IO (stdout)
import Test.Tasty (defaultMain)
import Test.Tasty.ExpectedFailure (ignoreTestBecause)
import Test.Tasty.HUnit (testCase, (@=?), (@?=))
import Test.Tasty.Runners (TestTree (TestGroup))
import TestMessages

-------------------
headers :: [Header]
headers =
  [ Header ("some-header", "some-value")
  , Header ("user-agent", "correct-value")
  , Header ("x-something", "something")
  ]

headersKeyTest :: TestTree
headersKeyTest = testCase "Extract key from header" $ do
  key (head headers) @=? "some-header"
  key (headers !! 1) @=? "user-agent"
  key (headers !! 2) @=? "x-something"

headersValueTest :: TestTree
headersValueTest = testCase "Extract value from header" $ do
  value (head headers) @=? "some-value"
  value (headers !! 1) @=? "correct-value"
  value (headers !! 2) @=? "something"

userAgentTest :: TestTree
userAgentTest = testCase "User-Agent header" $ do
  extractUserAgent headers @=? Just (Header ("user-agent", "correct-value"))
  extractUserAgent [Header ("useless", "value")] @?= Nothing

showHeaderTest :: TestTree
showHeaderTest = testCase "Show header" $ do
  show (Header ("USER-AGENT", "rAnDoMCasE")) @?= "USER-AGENT: rAnDoMCasE"

findNextIndexTest :: TestTree
findNextIndexTest = testCase "Find next index" $ do
  let clientsArray = [Client "not-undefined" undefined, Client "undefined" undefined]
  1 @=? findNextIndex (listArray (0, 255) clientsArray)

configurationTest :: TestTree
configurationTest = testCase "Read configuration" $ do
  conf <- readConfiguration (FromFile "hwedis.toml")
  fromMonad <- runConfigurationM conf (do getConfiguration)
  fromMonad @=? conf

  (rH, rP) <-
    runConfigurationM
      conf
      ( do
          cnf <- getConfiguration
          pure (getRedisHost cnf, getRedisPort cnf)
      )

  getWebserverHost conf @?= "0.0.0.0"
  getWebserverPort conf @?= 9092
  rH @?= "localhost"
  rP @?= 6379

type FakeClientM = ReaderT Connection (KatipT IO)

runFakeClient :: Connection -> LogEnv -> FakeClientM a -> IO a
runFakeClient t le m = runKatipT le (runReaderT m t)

-- Test the server
serverTest :: TestTree
serverTest = testCase "Test Server" $ do
  let serverHost = "127.0.0.1"
      serverPort = 9999

  ctx <- atomically $ newArray (0, 20) (Client "undefined" undefined) :: IO Environment
  idx <- newTVarIO 0 :: IO MutableIndex
  handleScribe <- mkHandleScribe (ColorLog True) stdout (permitItem ErrorS) V1
  le <- initLogEnv "hwedis" "test" >>= registerScribe "stdout" handleScribe defaultScribeSettings

  runKatipT le $ logMsg "main" DebugS "Starting server on dedicated thread"

  -- Run server on a dedicated light thread
  _ <- forkIO $ do
    runServer serverHost serverPort
      $ \pc -> runServerStack le (ctx, idx, undefined) $ do
        lift $ lift $ logMsg "main" DebugS "Starting webserver"
        serverApp' pc

  let duration = [D.µs| 2s |] :: Int
  threadDelay duration

  -- Collect messages on a dedicated thread
  res <- T.forkIO $ do
    runClientWith serverHost serverPort "/" defaultConnectionOptions [("User-Agent", "Test")] $ \conn -> do
      runFakeClient conn le msgCollector

  -- Connect to the server
  runClientWith serverHost serverPort "/" defaultConnectionOptions [("User-Agent", "Test")] $ \conn -> do
    runFakeClient conn le mainClient

  -- Gather the results
  msgs <- snd res >>= T.result
  length msgs @?= 1
  head msgs @?= DataMessage False False False (Text "put" Nothing)
 where
  msgCollector :: FakeClientM [Message]
  msgCollector = do
    conn <- ask

    liftKatip $ logMsg "collector" DebugS "Collecting messages"
    msg <- liftIO $ receive conn
    liftKatip $ logMsg "collector" DebugS "Received message"
    return [msg]

  mainClient :: FakeClientM ()
  mainClient = do
    conn <- ask

    liftKatip $ logMsg "client" DebugS "Sending Ping"
    liftIO $ send conn (ControlMessage (Ping "ping"))
    msg <- liftIO $ receive conn
    liftIO $ ControlMessage (Pong "ping") @=? msg

    liftKatip $ logMsg "client" DebugS "Sending Text message"
    -- liftIO $ send conn $ M.toWsMessage (M.PutMessage "Something")
    msg2 <- liftIO $ receive conn
    liftIO $ DataMessage False False False (Text "put" Nothing) @=? msg2

    liftKatip $ logMsg "client" DebugS "Stopping server"

  liftKatip = lift
  liftIO = lift . lift

main :: IO ()
main = defaultMain $ do
  TestGroup
    "ServerTest"
    [ TestGroup
        "Headers"
        [ headersKeyTest
        , headersValueTest
        , userAgentTest
        , showHeaderTest
        , findNextIndexTest
        , ignoreTestBecause "Refactoring needed" serverTest
        ]
    , TestGroup
        "Server"
        [findNextIndexTest]
    , TestGroup
        "Configuration"
        [configurationTest]
    , TestGroup
        "Messages"
        [ parseGetMessageTest
        , parseListMessageTest
        , parseBasicMessageTest
        , parseCreateMessageTest
        , parseUpdateMessageTest
        , parseDeleteMessageTest
        , parseWSMessage
        , testFmapR
        , testToByteString
        ]
    , TestGroup
        "Redis"
        [ testRedisPing
        , testRedisKeys
        , testAllKeys
        , testRedisHashes
        ]
    ]
