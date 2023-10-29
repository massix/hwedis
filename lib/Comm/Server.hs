{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Comm.Server (
  serverApp,
  Environment,
  MutableIndex,
  findNextIndex,
) where

-----------------------------------------------------

import Comm.Client (Client (..), getConnection', getUserAgent', mkClient)
import Control.Concurrent (forkIO, myThreadId, threadDelay, throwTo)
import Control.Concurrent.STM (TArray, TVar, writeTVar)
import Control.Exception (Exception)
import Control.Monad (forever)
import Control.Monad.Trans.Maybe (MaybeT (runMaybeT))
import Data.Array.MArray (getElems, writeArray)
import Data.Foldable (traverse_)
import GHC.Conc (ThreadId, atomically, readTVarIO)
import Network.WebSockets (Connection, ControlMessage (..), DataMessage (..), Message (..), ServerApp, receive, withPingThread, sendClose)
import Network.WebSockets.Connection (send)
import Data.Array (assocs, Array)
import Data.Array.IArray (listArray)

-----------------------------------------------------

-- | The Environment we're using is just a list of connected clients
type Environment = TArray Int Client

type MutableIndex = TVar Int

data InternalExceptions
  = ClientDisconnected
  deriving (Show)

instance Exception InternalExceptions

-- | Given an array of clients, find the next usable index (recycle)
findNextIndex :: Array Int Client -> Int
findNextIndex = fst . head . filter ((== "undefined") . getUserAgent' . snd ) . assocs

-- | Given an environment and a mutable index, returns a (PendingConnection -> IO ())
serverApp :: Environment -> MutableIndex -> ServerApp
serverApp env idx pc = do
  putStrLn "New connection incoming"
  client <- runMaybeT (mkClient pc)

  case client of
    Just c@(Client ua conn) -> do
      currentIndex <- readTVarIO idx
      forked <- forkIO forkedThread

      putStrLn $ "Client accepted, user agent: " ++ ua ++ " -- index: " ++ show currentIndex
      atomically $ writeArray env currentIndex c

      clients <- atomically $ getElems env
      atomically $ writeTVar idx $ findNextIndex $ listArray (0, 255) clients

      withPingThread conn 30 (pure ()) $ talk conn env forked currentIndex
    Nothing -> putStrLn "Client refused"
 where
  talk :: Connection -> Environment -> ThreadId -> Int -> IO ()
  talk conn ctx tid myIdx = forever $ do
    msg <- receive conn

    case msg of
      ControlMessage (Close _ bs) -> do
        putStrLn "Received close message"
        sendClose conn bs

        -- Remove the client from the array
        atomically $ writeArray env myIdx (Client "undefined" undefined)
        throwTo tid ClientDisconnected

      ControlMessage (Ping content) -> do
        putStrLn $ "Received ping message: " ++ show content
        send conn (ControlMessage (Pong ""))

      ControlMessage (Pong content) -> do
        putStrLn $ "Received pong message: " ++ show content

      DataMessage _ _ _ (Text _ _) -> do
        putStrLn $ "Received msg: " ++ show msg
        broadcast msg ctx

      DataMessage _ _ _ (Binary _) -> do
        putStrLn "Received binary msg"

  forkedThread :: IO ()
  forkedThread = forever $ do
    mid <- myThreadId
    threadDelay 10_000_000
    putStrLn $ "Forked thread for connection: " ++ show mid

  broadcast :: Message -> Environment -> IO ()
  broadcast msg ctx = do
    clients <- atomically $ getElems ctx
    let connected = filter ((/= "undefined") . getUserAgent') clients
    putStrLn $ "Broadcasting to " ++ show (length connected) ++ " clients"
    traverse_ (flip send msg . getConnection') connected
