module Main where

import Network.WebSockets (runServer)
import Comm.Server (serverApp, MutableIndex, Environment)
import Control.Concurrent.STM (atomically, STM, newTVar)
import Data.Array.MArray (newArray)
import Comm.Client (Client(..))

main :: IO ()
main = do
  ctx <- atomically mkContext
  idx <- atomically mkIndex

  runServer "0.0.0.0" 9091 (serverApp ctx idx)
 where
  mkContext :: STM Environment
  mkContext = newArray (0, 255) (Client "undefined" undefined)

  mkIndex :: STM MutableIndex
  mkIndex = newTVar 0

