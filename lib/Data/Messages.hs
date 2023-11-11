{-# LANGUAGE StarIsType #-}
{-# LANGUAGE ViewPatterns #-}

module Data.Messages (
  ToByteString (..),
  ToWsMessage (..),
  Request (..),
  Response (..),
  ObjectId,
  Field,
  fmapR,
  (<$*>),
  FromWsMessage (..),
  fromByteString,
  isBroadcastable,
  getField
) where

--------------------------------------------------------------------------------

import Control.Monad (MonadPlus (mzero))
import Data.ByteString (ByteString, toStrict)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Search as Search
import qualified Network.WebSockets as WS
import Data.List (nub)

--------------------------------------------------------------------------------

-- Request message grammar:
-- <ACTION>[<SEP><OBJID>[<SEP>(<FIELD><SEP>(<VALUE>|Nil))+]]
-- Where:
-- <SEP> the literal '::'
-- <ACTION>: one of 'G', 'C', 'D', 'U' or 'L' for 'GET', 'CREATE', 'DELETE', 'UPDATE', 'LIST'
-- <OBJID>: a string of length 8
-- Fields and values are valid only for 'U' and 'C' actions
-- <FIELD>: a string of length 1-24
-- <VALUE>: a string of length 1-256
-- Nil : literal string "Nil" used to delete a field (only useful for 'U' action)

-- Example: `C::someobje::field1::verylongvalueofmorethanabunchofcharacters::field2::shortfield`
--           ^_ this creates a new entry with ID "someobje" and two fields ("field1" and "field2")
--          `U::someobje::field2:AnotherLongField::field3::addedfield`
--          ^_ this updates someobje, modifying field2 to "AnotherLongField" and adding field3 (field1 will be left untouched)
--          `U::someobje::field1::Nil`
--          ^_ this will delete the field "field1" from the object "someobje", leaving the rest untouched
--          `D::someobje`
--          ^_ this will delete the object "someobje"
--          `G::someobje`
--          ^_ this will retrieve the object "someobje"

type ObjectId = ByteString
type Field = (ByteString, ByteString)

keyLength :: Int
keyLength = 24

valueLength :: Int
valueLength = 256

objIdLength :: Int
objIdLength = 8

-- Request Message (client -> hwedis)
data Request
  = List
  | Get ObjectId
  | Create ObjectId [Field]
  | Update ObjectId [Field]
  | Delete ObjectId
  deriving (Show, Eq)

-- Response Message (hwedis -> client)
data Response
  = ListR [(ObjectId, [Field])]
  | GetR ObjectId [Field]
  | CreateR ObjectId
  | UpdateR ObjectId
  | DeleteR ObjectId
  | Empty
  deriving (Show, Eq)

-- TypeClasses for common conversion
class FromWsMessage msg where
  fromWsMessage :: WS.Message -> Maybe msg

class FromByteString msg where
  fromByteString :: ByteString -> Maybe msg

class ToByteString msg where
  toByteString :: msg -> ByteString

class ToWsMessage msg where
  toWsMessage :: msg -> WS.Message

instance ToByteString Response where
  toByteString (CreateR o) = "C::" <> o
  toByteString (UpdateR o) = "U::" <> o
  toByteString (DeleteR o) = "D::" <> o
  toByteString (GetR o fields) = "G::" <> genObject (o, fields)
  toByteString (ListR objs) = "L::" <> BS.intercalate "||" (fmap genObject objs)
  toByteString Empty = "#f"

genObject :: (ObjectId, [Field]) -> ByteString
genObject (o, f) = o <> "::" <> BS.intercalate "::" (fmap (\(k, v) -> k <> "::" <> v) f)

instance ToWsMessage Response where
  toWsMessage x = WS.DataMessage False False False (WS.Text (WS.toLazyByteString $ toByteString x) Nothing)

isBroadcastable :: Response -> Bool
isBroadcastable (DeleteR _) = True
isBroadcastable (CreateR _) = True
isBroadcastable (UpdateR _) = True
isBroadcastable _ = False

getField :: ByteString -> [Field] -> Maybe Field
getField _ [] = Nothing
getField k (f@(fk, _):xs) = if fk == k then Just f else getField k xs

instance FromWsMessage Request where
  -- Cannot build from ControlMessages or Binary messages
  fromWsMessage (WS.ControlMessage _) = Nothing
  fromWsMessage (WS.DataMessage _ _ _ (WS.Binary _)) = Nothing
  fromWsMessage (WS.DataMessage _ _ _ (WS.Text bs _)) = fromByteString $ toStrict bs

instance FromByteString Request where
  fromByteString (C.unpack -> []) = Nothing
  fromByteString (C.unpack -> ['L']) = Just List
  fromByteString (C.unpack -> 'L' : _) = Nothing
  fromByteString (C.unpack -> v : xs)
    | v == 'G' = parseGetMessage (C.pack xs) >>= validateAll
    | v == 'C' = parseCreateMessage (C.pack xs) >>= validateAll
    | v == 'U' = parseUpdateMessage (C.pack xs) >>= validateAll
    | v == 'D' = parseDeleteMessage (C.pack xs) >>= validateAll
    | otherwise = Nothing
   where
    validateAll :: Request -> Maybe Request
    validateAll x = validateObjectId x >>= validateFields >>= validateNoDuplicates

    splitFields :: ByteString -> [ByteString]
    splitFields = filter (/= "") . Search.split "::"

    validationFunc :: Field -> Bool
    validationFunc (fk, fv) = BS.length fk < keyLength && BS.length fv < valueLength

    -- In the request we cannot accept duplicated fields
    validateNoDuplicates :: Request -> Maybe Request
    validateNoDuplicates (Create o fields) = 
      let noDups = nub $ fmap fst fields
      in if length noDups == length fields then pure $ Create o fields else mzero
    validateNoDuplicates (Update o fields) =
      let noDups = nub $ fmap fst fields
      in if length noDups == length fields then pure $ Update o fields else mzero
    validateNoDuplicates c = pure c

    validateFields :: Request -> Maybe Request
    validateFields List = pure List
    validateFields (Get x) = pure $ Get x
    validateFields (Delete x) = pure $ Delete x
    validateFields c@(Create _ fields) = do
      let validation = fmap validationFunc fields
      if any not validation then mzero else pure c
    validateFields c@(Update _ fields) = do
      let validation = fmap validationFunc fields
      if any not validation then mzero else pure c

    validateObjectId :: Request -> Maybe Request
    validateObjectId List = pure List
    validateObjectId g@(Get x) = if BS.length x == objIdLength then pure g else mzero
    validateObjectId d@(Delete x) = if BS.length x == objIdLength then pure d else mzero
    validateObjectId c@(Create x _) = if BS.length x == objIdLength then pure c else mzero
    validateObjectId u@(Update x _) = if BS.length x == objIdLength then pure u else mzero

    collectKV :: [ByteString] -> [Field]
    collectKV [] = []
    collectKV [y] = [(y, "")]
    -- \^ This should never happen, but just in case..
    collectKV [y, ys] = [(y, ys)]
    collectKV (y : ys) = (y, head ys) : collectKV (tail ys)

    parseMessageWithId :: (ByteString -> Request) -> ByteString -> Maybe Request
    parseMessageWithId f bs = do
      let splitted = splitFields bs
      if length splitted == 1
        then pure $ f $ head splitted
        else mzero

    parseMessageWithFields :: (ByteString -> [Field] -> Request) -> ByteString -> Maybe Request
    parseMessageWithFields f bs = do
      let splitted = splitFields bs
      if odd (length splitted) && length splitted >= 3
        then
          let objId = head splitted
           in pure $ f objId (collectKV $ tail splitted)
        else mzero

    parseGetMessage :: ByteString -> Maybe Request
    parseGetMessage = parseMessageWithId Get

    parseDeleteMessage :: ByteString -> Maybe Request
    parseDeleteMessage = parseMessageWithId Delete

    parseCreateMessage :: ByteString -> Maybe Request
    parseCreateMessage = parseMessageWithFields Create

    parseUpdateMessage :: ByteString -> Maybe Request
    parseUpdateMessage = parseMessageWithFields Update

-- | fmap for Requests, only acts on the fields, leaving the objId untouched
fmapR :: (Field -> Field) -> Request -> Request
fmapR f (Create objId fields) = Create objId $ f <$> fields
fmapR f (Update objId fields) = Update objId $ f <$> fields
fmapR _ x = x

infixl 6 <$*>
(<$*>) :: (Field -> Field) -> Request -> Request
(<$*>) = fmapR

