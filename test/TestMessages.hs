{-# LANGUAGE OverloadedStrings #-}

module TestMessages where

--------------------------------------------------------------------------------

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as C
import Data.Messages (
  FromWsMessage (fromWsMessage),
  Request (..),
  Response (..),
  ToByteString (toByteString),
  fmapR,
  fromByteString,
  (<$*>),
 )
import qualified Network.WebSockets as WS

import Test.Tasty
import Test.Tasty.HUnit

--------------------------------------------------------------------------------

parseBasicMessageTest :: TestTree
parseBasicMessageTest = testCase "Parse basic messages" $ do
  -- Wrong action ID
  (fromByteString "K::someobje::field1::value1" :: Maybe Request) @?= Nothing
  -- Empty message
  (fromByteString "" :: Maybe Request) @?= Nothing
  -- Random string
  (fromByteString "randomstring" :: Maybe Request) @?= Nothing
  -- Wrong syntax
  (fromByteString "L::" :: Maybe Request) @?= Nothing

parseGetMessageTest :: TestTree
parseGetMessageTest = testCase "Parse Get Message" $ do
  -- Ok
  (fromByteString "G::someobje" :: Maybe Request) @?= Just (Get "someobje")
  -- ID too long
  (fromByteString "G::toolongID" :: Maybe Request) @?= Nothing
  -- ID too short
  (fromByteString "G::shortID" :: Maybe Request) @?= Nothing
  -- Too many fields
  (fromByteString "G::someobje::somefield::somevalue" :: Maybe Request) @?= Nothing
  -- Wrong separator
  (fromByteString "G:someobje" :: Maybe Request) @?= Nothing
  -- Missing ID
  (fromByteString "G" :: Maybe Request) @?= Nothing
  -- Key too long
  let key = ['a' .. 'z']
  (fromByteString ("G::" <> C.pack key) :: Maybe Request) @?= Nothing

parseDeleteMessageTest :: TestTree
parseDeleteMessageTest = testCase "Parse Delete Message" $ do
  -- Ok
  (fromByteString "D::someobje" :: Maybe Request) @?= Just (Delete "someobje")
  -- ID too long
  (fromByteString "D::toolongID" :: Maybe Request) @?= Nothing
  -- ID too short
  (fromByteString "D::shortID" :: Maybe Request) @?= Nothing
  -- Too many fields
  (fromByteString "D::someobje::somefield::somevalue" :: Maybe Request) @?= Nothing
  -- Wrong separator
  (fromByteString "D:someobje" :: Maybe Request) @?= Nothing
  -- Missing ID
  (fromByteString "D" :: Maybe Request) @?= Nothing
  -- Key too long
  (fromByteString ("D::" <> C.pack ['a' .. 'z']) :: Maybe Request) @?= Nothing

parseUpdateMessageTest :: TestTree
parseUpdateMessageTest = testCase "Parse Update Message" $ do
  -- Ok
  fromByteString "U::someobje::field1::value1::field2::value2"
    @?= Just (Update "someobje" [("field1", "value1"), ("field2", "value2")])
  -- ID too long
  (fromByteString "U::toolongID::field1::value1" :: Maybe Request) @?= Nothing
  -- ID too short
  (fromByteString "U::shortID::field1::value1" :: Maybe Request) @?= Nothing
  -- odd fields
  (fromByteString "U::someobje::field1::value1::field2" :: Maybe Request) @?= Nothing
  -- no fields
  (fromByteString "U::someobje" :: Maybe Request) @?= Nothing
  -- field key too long
  let key = ['A' .. 'z']
  (fromByteString ("U::someobje::" <> C.pack key <> "::value1") :: Maybe Request) @?= Nothing
  -- field value too long
  let value = ['A' .. 'z'] <> ['A' .. 'z'] <> ['A' .. 'z'] <> ['A' .. 'z'] <> ['A' .. 'z']
  (fromByteString ("U::someobje::validkey::" <> C.pack value) :: Maybe Request) @?= Nothing
  -- duplicated fields
  (fromByteString "U::someobje::field1::value1::field2::value2::field1::differentvalue" :: Maybe Request)
    @?= Nothing

parseCreateMessageTest :: TestTree
parseCreateMessageTest = testCase "Parse Create Message" $ do
  -- Ok
  fromByteString "C::someobje::field1::value1::field2::value2"
    @?= Just (Create "someobje" [("field1", "value1"), ("field2", "value2")])
  -- ID too long
  (fromByteString "C::toolongID::field1::value1" :: Maybe Request) @?= Nothing
  -- ID too short
  (fromByteString "C::shortID::field1::value1" :: Maybe Request) @?= Nothing
  -- odd fields
  (fromByteString "C::someobje::field1::value1::field2" :: Maybe Request) @?= Nothing
  (fromByteString "C::someobje::field1" :: Maybe Request) @?= Nothing
  -- no fields
  (fromByteString "C::someobje" :: Maybe Request) @?= Nothing
  -- duplicated fields
  (fromByteString "C::someobje::field1::value1::field1::value2" :: Maybe Request) @?= Nothing

parseListMessageTest :: TestTree
parseListMessageTest = testCase "Parse List Message" $ do
  -- OK
  (fromByteString "L" :: Maybe Request) @?= Just List
  -- Too many arguments
  (fromByteString "L::someobje" :: Maybe Request) @?= Nothing

parseWSMessage :: TestTree
parseWSMessage = testCase "Parse WS Message" $ do
  -- OK
  fromWsMessage (buildWsMessage "G::someobje") @=? Just (Get "someobje")
  fromWsMessage (buildWsMessage "D::someobje") @=? Just (Delete "someobje")
  fromWsMessage (buildWsMessage "U::someobje::field1::value1::field2::value2")
    @=? Just (Update "someobje" [("field1", "value1"), ("field2", "value2")])
  fromWsMessage (buildWsMessage "C::someobje::field1::value1::field2::value2")
    @=? Just (Create "someobje" [("field1", "value1"), ("field2", "value2")])
  fromWsMessage (buildWsMessage "L") @=? Just List
  -- KO (Wrong Message)
  fromWsMessage (buildWsMessage "K") @=? (Nothing :: Maybe Request)
  fromWsMessage (buildWsMessage "K::someobje") @=? (Nothing :: Maybe Request)
  fromWsMessage (buildWsMessage "G::someobje::field1::value1") @=? (Nothing :: Maybe Request)
  -- KO (Wrong Message Type)
  fromWsMessage (WS.ControlMessage (WS.Ping "1")) @=? (Nothing :: Maybe Request)
  fromWsMessage (WS.ControlMessage (WS.Pong "1")) @=? (Nothing :: Maybe Request)
  fromWsMessage (WS.ControlMessage (WS.Close 0 "")) @=? (Nothing :: Maybe Request)
  fromWsMessage (WS.DataMessage False False False (WS.Binary "")) @=? (Nothing :: Maybe Request)
 where
  buildWsMessage :: ByteString -> WS.Message
  buildWsMessage x = WS.DataMessage False False False (WS.Text (WS.toLazyByteString x) Nothing)

testFmapR :: TestTree
testFmapR = testCase "fmapR" $ do
  let func (k, v) = (k, v <> " with fmapR")
  fmapR func List @?= List
  fmapR func (Get "someobje") @?= Get "someobje"
  fmapR func (Delete "someobje") @?= Delete "someobje"
  fmapR func (Create "someobje" [("field1", "value1"), ("field2", "value2")])
    @?= Create "someobje" [("field1", "value1 with fmapR"), ("field2", "value2 with fmapR")]

  func
    <$*> Update "someobje" [("field1", "value1"), ("field2", "value2")]
    @?= Update "someobje" [("field1", "value1 with fmapR"), ("field2", "value2 with fmapR")]

testToByteString :: TestTree
testToByteString = testCase "Response to ByteString" $ do
  toByteString (GetR "someobje" [("field1", "value1"), ("field2", "value2")])
    @?= "G::someobje::field1::value1::field2::value2"
  toByteString (CreateR "someobje") @?= "C::someobje"
  toByteString (UpdateR "someobje") @?= "U::someobje"
  toByteString (DeleteR "someobje") @?= "D::someobje"

  toByteString
    ( ListR
        [ ("someobje", [("field1", "value1"), ("field2", "value2")])
        , ("differen", [("field1", "otherv"), ("field3", "something")])
        , ("lastobje", [("uniquefield", "longervalues")])
        ]
    )
    @?= "L::someobje::field1::value1::field2::value2||"
    <> "differen::field1::otherv::field3::something||"
    <> "lastobje::uniquefield::longervalues"

  toByteString Empty @?= "#f"
