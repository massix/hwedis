{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}

--------------------------------------------------------------------------------

module Data.Configuration (
  ConfigurationSource (..),
  Configuration (..),
  ConfigurationM,
  getConfiguration,
  mkConfigurationM,
  runConfigurationM,
  readConfiguration
) where

--------------------------------------------------------------------------------

import Control.Exception (IOException, try)
import Control.Monad (when)
import System.IO (Handle, IOMode (ReadMode), hClose, hGetContents, hIsOpen, hPutStr, openFile, stderr)
import Toml (TomlCodec, (.=), decode)
import qualified Toml.Codec as Toml
import Data.String (fromString)
import Control.Monad.Trans.Class (MonadTrans (lift), lift)
import Control.Monad.Trans.Reader (ReaderT (runReaderT), ask)
import Control.Monad.Trans (MonadIO, liftIO)

--------------------------------------------------------------------------------

data ConfigurationSource
  = FromFile FilePath
  | FromSQLite FilePath
  | FromEnvironment
  deriving (Show)

data Configuration = Configuration
  { getWebserverHost :: !String
  , getWebserverPort :: !Int
  , getRedisHost :: !String
  , getRedisPort :: !Int
  }
  deriving (Show, Read, Eq)

class Defaultable t where
  getDefault :: t

configurationCodec :: TomlCodec Configuration
configurationCodec =
  Configuration
    <$> Toml.string "webserver.host"
    .= getWebserverHost
    <*> Toml.int "webserver.port"
    .= getWebserverPort
    <*> Toml.string "redis.host"
    .= getRedisHost
    <*> Toml.int "redis.port"
    .= getRedisPort

instance Defaultable Configuration where
  getDefault = Configuration "0.0.0.0" 9091 "127.0.0.1" 6379

readConfiguration :: ConfigurationSource -> IO Configuration
readConfiguration (FromFile fp) = do
  handle <- try $ openFile fp ReadMode :: IO (Either IOException Handle)
  case handle of
    Left err -> do
      hPutStr stderr $ "Exception occured while reading file: " ++ show err ++ "\n"
      hPutStr stderr "Returning default configuration.\n"
      pure getDefault
    Right h -> do
      contents <- hGetContents h
      hIsOpen h >>= \r -> when r $ hClose h
      let result = decode configurationCodec $ fromString contents
      case result of
        Left _ -> do
          hPutStr stderr "Could not parse TOML file"
          pure getDefault
        Right c -> pure c
readConfiguration (FromSQLite _) = undefined
readConfiguration FromEnvironment = undefined

-- A Monad that allows for the configuration to be injected within another monad
newtype ConfigurationM m a = ConfigurationM { unConfigurationM :: ReaderT Configuration m a }

instance (Monad m) => Functor (ConfigurationM m) where
  fmap :: (a -> b) -> ConfigurationM m a -> ConfigurationM m b
  fmap func m = ConfigurationM $ func <$> unConfigurationM m

instance (Monad m) => Applicative (ConfigurationM m) where
  pure :: a -> (ConfigurationM m) a
  pure = ConfigurationM . pure

  (<*>) :: ConfigurationM m (a -> b) -> ConfigurationM m a -> ConfigurationM m b
  f <*> m =
    let src = unConfigurationM m
        func = unConfigurationM f
    in ConfigurationM $ func <*> src

instance (Monad m) => Monad (ConfigurationM m) where
  (>>=) :: ConfigurationM m a -> (a -> ConfigurationM m b) -> ConfigurationM m b
  m >>= f = ConfigurationM $ unConfigurationM m >>= \e -> unConfigurationM (f e)

instance MonadTrans ConfigurationM where
  lift :: (Monad m) => m a -> ConfigurationM m a
  lift = ConfigurationM . lift

instance (MonadIO m) => MonadIO (ConfigurationM m) where
  liftIO :: (Monad m) => IO a -> ConfigurationM m a
  liftIO = lift . liftIO

getConfiguration :: (Monad m) => ConfigurationM m Configuration
getConfiguration = ConfigurationM ask

mkConfigurationM :: ConfigurationSource -> ConfigurationM IO Configuration
mkConfigurationM = lift . readConfiguration

runConfigurationM :: (Monad m) => Configuration -> ConfigurationM m a -> m a
runConfigurationM conf m = runReaderT (unConfigurationM m) conf
