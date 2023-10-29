module Main where

--------------------
import Comm.Client (Client (Client), Header (Header), extractUserAgent, key, value)
import Comm.Server (findNextIndex)
import Data.Array.IArray (listArray)
import Test.Tasty (defaultMain)
import Test.Tasty.HUnit (testCase, (@=?), (@?=))
import Test.Tasty.Runners (TestTree (TestGroup))

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
        ]
    , TestGroup
        "Server"
        [findNextIndexTest]
    ]
