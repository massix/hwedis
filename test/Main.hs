{-# LANGUAGE OverloadedStrings #-}

module Main where

--------------------
import Network.Client (Client (Client), Header (Header), extractUserAgent, key, value)
import Network.Server (Environment, MutableIndex, findNextIndex, runServerStack, serverApp')
import Control.Concurrent (ThreadId, forkIO, throwTo)
import Control.Concurrent.STM (atomically, newTVarIO)
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
import GHC.IO.Exception (FixIOException (FixIOException))
import Katip (ColorStrategy (..), KatipT, LogEnv, Severity (..), Verbosity (V3), defaultScribeSettings, initLogEnv, logMsg, mkHandleScribe, permitItem, registerScribe, runKatipT)
import Network.WebSockets (Connection, ControlMessage (..), DataMessage (..), Message (..), defaultConnectionOptions, receive, runClientWith, runServer, send)
import System.IO (stdout)
import Test.Tasty (defaultMain)
import Test.Tasty.HUnit (testCase, (@=?), (@?=))
import Test.Tasty.Runners (TestTree (TestGroup))
import qualified Control.Concurrent.Thread as T

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

  (redisHost, redisPort) <-
    runConfigurationM
      conf
      ( do
          cnf <- getConfiguration
          pure (getRedisHost cnf, getRedisPort cnf)
      )

  getWebserverHost conf @?= "0.0.0.0"
  getWebserverPort conf @?= 9092
  redisHost @?= "localhost"
  redisPort @?= 6379

type FakeClientM = ReaderT (ThreadId, Connection) (KatipT IO)

runFakeClient :: (ThreadId, Connection) -> LogEnv -> FakeClientM a -> IO a
runFakeClient t le m = runKatipT le (runReaderT m t)

-- Test the server
serverTest :: TestTree
serverTest = testCase "Test Server" $ do
  let serverHost = "127.0.0.1"
      serverPort = 9999

  ctx <- atomically $ newArray (0, 20) (Client "undefined" undefined) :: IO Environment
  idx <- newTVarIO 0 :: IO MutableIndex
  handleScribe <- mkHandleScribe (ColorLog True) stdout (permitItem DebugS) V3
  le <- initLogEnv "hwedis" "test" >>= registerScribe "stdout" handleScribe defaultScribeSettings

  runKatipT le $ logMsg "main" DebugS "Starting server on dedicated thread"

  -- Run server on a dedicated light thread
  threadId <- forkIO $ do
    runServer serverHost serverPort
      $ \pc -> runServerStack le (ctx, idx) $ do
        lift $ lift $ logMsg "main" DebugS "Starting webserver"
        serverApp' pc

  -- Collect messages on a dedicated thread
  res <- T.forkIO $ do
    runClientWith serverHost serverPort "/" defaultConnectionOptions [("User-Agent", "Test")] $ \conn -> do
      runFakeClient (undefined, conn) le msgCollector

  -- Connect to the server
  runClientWith serverHost serverPort "/" defaultConnectionOptions [("User-Agent", "Test")] $ \conn -> do
    runFakeClient (threadId, conn) le mainClient

  -- Gather the results
  msgs <- snd res >>= T.result
  length msgs @?= 1
  head msgs @?= DataMessage False False False (Text "Hello World" Nothing)

 where
  msgCollector :: FakeClientM [Message]
  msgCollector = do
    ctx <- ask
    let conn = snd ctx

    liftKatip $ logMsg "collector" DebugS "Collecting messages"
    msg <- liftIO $ receive conn
    liftKatip $ logMsg "collector" DebugS "Received message"
    return [msg]

  mainClient :: FakeClientM ()
  mainClient = do
    ctx <- ask
    let conn = snd ctx
        threadId = fst ctx

    liftKatip $ logMsg "client" DebugS "Sending Ping"
    liftIO $ send conn (ControlMessage (Ping "ping"))
    msg <- liftIO $ receive conn
    liftIO $ ControlMessage (Pong "ping") @=? msg

    liftKatip $ logMsg "client" DebugS "Sending Text message"
    liftIO $ send conn (DataMessage False False False (Text "Hello World" Nothing))
    msg2 <- liftIO $ receive conn
    liftIO $ DataMessage False False False (Text "Hello World" Nothing) @=? msg2

    -- Stop the running server
    liftKatip $ logMsg "client" DebugS "Stopping server"
    liftIO $ throwTo threadId FixIOException

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
        , serverTest
        ]
    , TestGroup
        "Server"
        [findNextIndexTest]
    , TestGroup
        "Configuration"
        [configurationTest]
    ]
