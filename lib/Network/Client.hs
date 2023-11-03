{-# LANGUAGE InstanceSigs #-}

module Network.Client (
  mkClient,
  Client(..),
  getUserAgent,
  getUserAgent',
  getConnection,
  getConnection',
  MaybeClient,
  Header(..),
  key,
  value,
  extractUserAgent
) where

----------------------------------

import Control.Monad (MonadPlus (mzero))
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Maybe (MaybeT)
import Data.Char (toLower)
import Data.Functor ((<&>))
import Data.String (IsString (fromString))
import Network.WebSockets (Connection, PendingConnection, RequestHead (requestHeaders), acceptRequest, pendingRequest, rejectRequest)

----------------------------------

type UserAgent = String
data Client = Client UserAgent Connection
newtype Header = Header (String, String)

instance Show Header where
  show :: Header -> String
  show (Header (first, second)) = first ++ ": " ++ second

instance Eq Header where
  (==) :: Header -> Header -> Bool
  (Header (x, y)) == (Header (x', y')) = x == x' && y == y'

type MaybeClient = MaybeT IO Client

userAgent :: String
userAgent = "user-agent"

getHeaders :: PendingConnection -> [Header]
getHeaders pc = do
  (k, v) <- requestHeaders (pendingRequest pc)
  pure $ Header (toLower <$> removeQuotes (show k), toLower <$> removeQuotes (show v))
 where
  removeQuotes :: String -> String
  removeQuotes = filter (/= '"')

-- | Extracts the key from the header
-- >>> key (Header ("user-agent", "value"))
-- "user-agent"
key :: Header -> String
key (Header (k, _)) = k

-- | Extracts the value from the header
-- >>> value (Header ("user-agent", "value"))
-- "value"
value :: Header -> String
value (Header (_, v)) = v

-- | Tries to extract the user-agent from the request
-- >>> extractUserAgent [Header("x-some-header", "useless"), Header("x-some-other-header", "useless")]
-- Nothing
--
-- >>> extractUserAgent [Header("x-some-header", "useless"), Header("user-agent", "Firefox")]
-- Just "user-agent": "Firefox"
extractUserAgent :: [Header] -> Maybe Header
extractUserAgent = toMaybe . filter ((== userAgent) . key)
 where
  toMaybe :: [Header] -> Maybe Header
  toMaybe f = if null f then Nothing else Just $ head f

-- | Extracts the IO UserAgent from the IO Client
getUserAgent :: IO Client -> IO UserAgent
getUserAgent = (<&> getUserAgent')

getUserAgent' :: Client -> String
getUserAgent' (Client u _) = u

-- | Extracts an IO Connection from an IO Client
getConnection :: IO Client -> IO Connection
getConnection = (<&> getConnection')

getConnection' :: Client -> Connection
getConnection' (Client _ c) = c

-- | Tries to create a new client from a "PendingConnection"
-- this function will return a Nothing if no User-Agent header is found
mkClient :: PendingConnection -> MaybeClient
mkClient pc = do
  let headers = getHeaders pc
      ua = extractUserAgent headers

  case ua of
    Just x -> do
      conn <- liftIO $ acceptRequest pc
      pure $ Client (value x) conn
    Nothing -> do
      liftIO $ rejectRequest pc (fromString "Missing User-Agent header")
      mzero

