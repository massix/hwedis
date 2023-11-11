{-# LANGUAGE OverloadedStrings #-}

module RedisTest where

--------------------------------------------------------------------------------

import Data.Either (fromLeft, fromRight, isLeft, isRight)
import Data.Foldable (traverse_)
import qualified Data.Text as T
import qualified Database.Redis as R
import qualified Katip as K
import Network.Redis
import System.IO (stdout)
import Test.Tasty
import Test.Tasty.HUnit
import qualified TestContainers.Tasty as TC

--------------------------------------------------------------------------------

data Endpoints = Endpoints
  { redisHost :: String
  , redisPort :: Int
  }
  deriving (Show)

-- Setup Container for Redis
setupContainer :: TC.TestContainer Endpoints
setupContainer = do
  redisContainer <-
    TC.run
      $ TC.containerRequest TC.redis
      TC.& TC.setExpose [6379]
      TC.& TC.setWaitingFor (TC.waitUntilMappedPortReachable 6379)
  let (addr, port) = TC.containerAddress redisContainer 6379

  pure $ Endpoints (T.unpack addr) port

setupTest :: IO Endpoints -> IO (K.LogEnv, R.Connection)
setupTest ep = do
  endpoints <- ep
  handleScribe <- K.mkHandleScribe K.ColorIfTerminal stdout (K.permitItem K.ErrorS) K.V1
  le <- K.initLogEnv "hwedis" "production" >>= K.registerScribe "stdout" handleScribe K.defaultScribeSettings
  conn <- R.checkedConnect R.defaultConnectInfo{R.connectHost = redisHost endpoints, R.connectPort = R.PortNumber $ fromIntegral (redisPort endpoints)}

  pure (le, conn)

testRedisPing :: TestTree
testRedisPing = TC.withContainers setupContainer $ \start -> do
  testCase "Ping Redis" $ do
    (le, conn) <- setupTest start

    r <- runRedisT conn le pingRedis
    isRight r @? "Result is right"

testRedisKeys :: TestTree
testRedisKeys = TC.withContainers setupContainer $ \start -> do
  testCase "Keys" $ do
    (le, conn) <- setupTest start

    r <- runRedisT conn le $ keyExists "randomkey"
    isRight r @? "Result is left while it should be right"
    fromRight True r @?= False

testAllKeys :: TestTree
testAllKeys = TC.withContainers setupContainer $ \start -> do
  testCase "All keys" $ do
    (le, conn) <- setupTest start

    r <- runRedisT conn le allKeys
    isRight r @? "Result is left while it should be right"

    fromRight ["bla"] r @?= []

    traverse_ (\obj -> runRedisT conn le $ newHash obj [("key1", "value1")]) ["key1", "key2", "key3", "key4"]
    r2 <- runRedisT conn le allKeys
    isRight r2 @? "Result is left while it should be right"
    length (fromRight ["bla"] r2) @?= 4 -- keys are not sorted, this is enough for now

testRedisHashes :: TestTree
testRedisHashes = TC.withContainers setupContainer $ \start -> do
  testCase "Hashes" $ do
    (le, conn) <- setupTest start

    r <- runRedisT conn le (getHash "notexisting")
    isLeft r @? "Result is right while it should be left"
    fromLeft "" r @?= "\"Key notexisting does not exist\""

    r2 <- runRedisT conn le (newHash "randomkey" [("key1", "value1"), ("key2", "value2")])
    isRight r2 @? "Result is left while it should be right"

    r3 <- runRedisT conn le $ keyExists "randomkey"
    isRight r3 @? "Result is left while it should be right"
    fromRight False r3 @?= True

    r4 <- runRedisT conn le $ getHash "randomkey"
    isRight r4 @? "Result is left while it should be right"

    fromRight ("", []) r4 @?= ("randomkey", [("key1", "value1"), ("key2", "value2")])

    _ <-
      runRedisT conn le
        $ newHash
          "removeme"
          [ ("key1", "value1")
          , ("key2", "value2")
          , ("key3", "value3")
          , ("key4", "value4")
          ]

    r5 <- runRedisT conn le $ removeHash "removeme"
    isRight r5 @? "Result is left while it should be right"

    r6 <- runRedisT conn le $ keyExists "removeme"
    fromRight True r6 @?= False

    r7 <- runRedisT conn le $ updateHash "randomkey" [("key1", "newvalue1"), ("key3", "value3")]
    isRight r7 @? "Result is left while it should be right"

    r8 <- runRedisT conn le $ getHash "randomkey"
    isRight r8 @? "Result is left while it should be right"
    fromRight ("", []) r8 @?= ("randomkey", [("key1", "newvalue1"), ("key2", "value2"), ("key3", "value3")])

    r9 <- runRedisT conn le $ updateHash "nonexisting" [("key1", "value1")]
    isLeft r9 @? "Result is right while it should be left"
