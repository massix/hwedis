{-# LANGUAGE OverloadedStrings #-}

module Main where

import Comm.Client (Client (..))
import Control.Concurrent.STM (STM, atomically, newTVar)
import Data.Array.MArray (newArray)
import Katip.Core (permitItem, logMsg, runKatipT)
import Network.WebSockets (runServer)
import System.IO (stdout)
import Comm.Server (Environment, MutableIndex, runServerStack, serverApp')
import Katip (mkHandleScribe, ColorStrategy (..), Severity (..), Verbosity (..), initLogEnv, registerScribe, defaultScribeSettings)
import Data.Configuration
    ( readConfiguration,
      getWebserverHost,
      getWebserverPort,
      ConfigurationSource(..) )
import Control.Monad.Trans (lift)

main :: IO ()
main = do
  -- Init TVar and TArray
  ctx <- atomically mkContext
  idx <- atomically mkIndex

  -- Init KatipT
  handleScribe <- mkHandleScribe (ColorLog True) stdout (permitItem InfoS) V2
  le <- initLogEnv "hwedis" "production" >>= registerScribe "stdout" handleScribe defaultScribeSettings

  -- Read Configuration from file
  -- TODO: give the possibility to read the configuration from different places
  conf <- readConfiguration (FromFile "hwedis.toml")

  runKatipT le $ logMsg "main" InfoS "Initializing server"

  -- Launch the server
  runServer (getWebserverHost conf) (getWebserverPort conf)
    $ \pc -> runServerStack le (ctx, idx) $ do 
      lift $ lift $ logMsg "main" InfoS "Starting webserver"
      serverApp' pc

 where
  mkContext :: STM Environment
  mkContext = newArray (0, 255) (Client "undefined" undefined)

  mkIndex :: STM MutableIndex
  mkIndex = newTVar 0
