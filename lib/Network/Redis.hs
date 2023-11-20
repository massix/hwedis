{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Redis (
  RedisT,
  runRedisT,
  pingRedis,
  getHash,
  newHash,
  keyExists,
  removeHash,
  updateHash,
  allKeys
) where

--------------------------------------------------------------------------------

import Control.Monad.Except (MonadError (catchError, throwError), unless, when)
import Control.Monad.Trans (MonadIO, lift, liftIO)
import Control.Monad.Trans.Except (ExceptT, runExceptT)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Database.Redis as R
import qualified Katip as K

--------------------------------------------------------------------------------

newtype RedisT a = RedisT {unRedisT :: ExceptT String (K.KatipT R.Redis) a}
  deriving (Functor, Applicative, Monad)

runRedisT :: R.Connection -> K.LogEnv -> RedisT a -> IO (Either String a)
runRedisT conn le ra =
  let katipT = runExceptT (unRedisT ra)
      redis = K.runKatipT le katipT
   in R.runRedis conn redis

instance R.MonadRedis RedisT where
  liftRedis = RedisT . lift . lift

instance MonadIO RedisT where
  liftIO = R.liftRedis . liftIO

instance MonadError String RedisT where
  throwError = RedisT . throwError . show
  catchError m h = RedisT $ catchError (unRedisT m) (unRedisT . h)

-- For internal use only
liftKatip :: K.KatipT R.Redis a -> RedisT a
liftKatip = RedisT . lift

logK :: (K.Katip m, Applicative m) => K.Severity -> String -> m ()
logK sev s = K.logMsg "redis" sev $ K.ls s

allKeys :: RedisT [ByteString]
allKeys = do
  resE <- R.liftRedis $ R.keys "*"
  either handleError pure resE
 where
  handleError :: R.Reply -> RedisT a
  handleError err = do
    liftKatip $ logK K.ErrorS $ "Failure while listing keys: " ++ show err
    throwError $ show err

keyExists :: B.ByteString -> RedisT Bool
keyExists key = do
  resE <- R.liftRedis $ R.exists key
  either handleError pure resE
 where
  handleError :: R.Reply -> RedisT b
  handleError e = do
    liftKatip $ logK K.ErrorS $ "Failure while checking if key exists: " ++ show e
    throwError $ show e

getHash :: B.ByteString -> RedisT (ByteString, [(ByteString, ByteString)])
getHash key = do
  exists <- keyExists key
  if exists
    then do
      res <- R.liftRedis $ R.hgetall key
      case res of
        Left err -> do
          liftKatip $ logK K.ErrorS $ "Failure while retrieving from Redis: " ++ show err
          throwError $ show err
        Right r -> pure (key, r)
    else throwError $ "Key " ++ B.unpack key ++ " does not exist"

pingRedis :: RedisT ()
pingRedis = do
  liftKatip $ logK K.DebugS "Pinging Redis..."
  status <- R.liftRedis R.ping
  either (throwError . show) handleStatus status

 where
  handleStatus :: R.Status -> RedisT ()
  handleStatus R.Ok = pure ()
  handleStatus R.Pong = pure ()
  handleStatus (R.Status bs) = throwError $ B.unpack bs

newHash :: ByteString -> [(ByteString, ByteString)] -> RedisT ()
newHash key fields = do
  liftKatip $ logK K.DebugS $ "Adding key to Redis: " ++ B.unpack key
  e <- keyExists key

  when e $ do
    liftKatip $ logK K.ErrorS $ "Key already exists: " ++ B.unpack key
    throwError "Key already exist"

  res <- R.liftRedis $ R.hmset key fields
  either handleError handleStatus res
 where
  handleError :: R.Reply -> RedisT a
  handleError err = do
    liftKatip $ logK K.ErrorS $ "Failure while adding to Redis: " ++ show err
    throwError $ show err

  handleStatus :: R.Status -> RedisT ()
  handleStatus (R.Status bs) = do
    liftKatip $ logK K.InfoS $ "Received status: " ++ B.unpack bs
    throwError $ B.unpack bs
  handleStatus R.Ok = liftKatip $ logK K.DebugS "Success"
  handleStatus R.Pong = liftKatip $ logK K.ErrorS "Pong received"

removeHash :: ByteString -> RedisT ()
removeHash key = do
  liftKatip $ logK K.InfoS $ "Removing hash from Redis: " ++ B.unpack key
  e <- keyExists key
  unless e $ throwError "Key does not exist"

  -- Retrieve all the keys for the hash
  (hashId, fields) <- getHash key
  res <- R.liftRedis $ R.hdel hashId $ fmap fst fields
  either handleError (handleResult $ length fields) res
 where
  handleError :: R.Reply -> RedisT a
  handleError err = do
    liftKatip $ logK K.ErrorS $ "Failure while removing from Redis: " ++ show err
    throwError $ show err

  handleResult :: Int -> Integer -> RedisT ()
  handleResult fields x = if x == fromIntegral fields then pure () else throwError "Could not remove all fields"

updateHash :: ByteString -> [(ByteString, ByteString)] -> RedisT ()
updateHash key fields = do
  exists <- keyExists key
  unless exists $ throwError "Key does not exist"
  res <- R.liftRedis $ R.hmset key fields
  either handleError handleStatus res
 where
  handleError :: R.Reply -> RedisT a
  handleError err = do
    liftKatip $ logK K.ErrorS $ "Failure while updating hash: " ++ show err
    throwError $ show err
  handleStatus :: R.Status -> RedisT ()
  handleStatus R.Ok = pure ()
  handleStatus R.Pong = throwError "Pong received"
  handleStatus (R.Status bs) = throwError $ B.unpack bs

