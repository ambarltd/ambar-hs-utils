{-# LANGUAGE UndecidableInstances #-}

module Database.SQLServer
  ( Connection
  , ConnectionInfo(..)
  , withConnection

  , Query
  , mkQuery
  , mkQuery_
  , mkQueryMany
  , query
  , queryWith
  , execute
  , FromRow(..)
  , Row(..)
  , RowParser
  , FromField(..)
  , Field(..)
  , FieldParser
  , parseFieldWith
  , parseField

  , isEndOfRow
  , fieldInfo
  , rawBytes
  , ToField(..)
  , ToRow
  , Only(..)
  )
  where

import Control.Applicative (Alternative(..))
import Control.Concurrent (newMVar, withMVar)
import Control.Exception (Exception, ErrorCall(..), throwIO, try, evaluate, bracket)
import qualified Data.ByteString.Base16 as Base16
import qualified Data.Base16.Types as Base16
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LB
import qualified Data.Text as Text
import Data.Text (Text)
import Data.Word (Word16)
import System.IO.Unsafe (unsafePerformIO)

import qualified Database.MSSQLServer.Connection as M
import qualified Database.MSSQLServer.Query as M
import qualified Database.Tds.Message as M
import Util.Exception (annotateWith)

data ConnectionInfo = ConnectionInfo
  { conn_host :: Text
  , conn_port :: Word16
  , conn_username :: Text
  , conn_password :: Text
  , conn_database :: Text
  }

-- Run an action with one of the active connections.
newtype Connection = Connection (forall a. (M.Connection -> IO a) -> IO a)

-- | The underlying SQL Server library only accepts one operation per connection.
withConnection :: ConnectionInfo -> (Connection -> IO a) -> IO a
withConnection ConnectionInfo{..} f =
  bracket connect disconnect $ \conn -> do
    var <- newMVar conn
    f $ Connection $ \g -> withMVar var g
  where
  connect =
    M.connect M.defaultConnectInfo
      { M.connectHost = Text.unpack conn_host
      , M.connectPort = show conn_port
      , M.connectDatabase = Text.unpack conn_database
      , M.connectUser = Text.unpack conn_username
      , M.connectPassword = Text.unpack conn_password
      , M.connectEncryption = 0x02
      }

  disconnect = M.close

newtype Query = Query Text
  deriving (Show)

class ToField a where
  toField :: a -> Text

instance ToField Text where toField txt = "'" <> txt <> "'"
instance ToField String where toField = toField . Text.pack
instance ToField Int where toField = Text.pack . show
instance ToField Double where toField = Text.pack . show
instance ToField ByteString where
  toField bs = "0x" <> Base16.extractBase16 (Base16.encodeBase16 bs)

instance ToField a => ToField (Maybe a) where
  toField = \case
    Nothing -> "Null"
    Just v -> toField v

class ToRow a where
  toRow :: a -> [Text]

data Only a = Only a
  deriving (Eq, Show)

instance ToRow () where toRow () = []
instance ToField a =>
  ToRow (Only a) where toRow (Only a) = [toField a]
instance (ToField a, ToField b) =>
  ToRow (a, b) where toRow (a, b) = [toField a, toField b]
instance (ToField a, ToField b, ToField c) =>
  ToRow (a, b, c) where toRow (a, b, c) = [toField a, toField b, toField c]
instance (ToField a, ToField b, ToField c, ToField d) =>
  ToRow (a, b, c, d) where toRow (a, b, c, d) = [toField a, toField b, toField c, toField d]
instance (ToField a, ToField b, ToField c, ToField d, ToField e) =>
  ToRow (a, b, c, d, e) where toRow (a, b, c, d, e) = [toField a, toField b, toField c, toField d, toField e]

mkQuery_ :: String -> Query
mkQuery_ = mkQuery () . Text.pack

mkQuery :: ToRow args => args -> Text -> Query
mkQuery args_raw body = Query merged
  where
  merged =
    if argsFound /= argsExpected
    then error $ unwords
      [ "Invalid arguments for query. Expected "
      , show argsExpected
      , " but got "
      , show argsFound
      , " in:\n"
      , Text.unpack body
      ]
    else Text.unwords $ interleave parts args
  args = toRow args_raw
  parts = Text.splitOn "?" body
  argsExpected = length parts - 1
  argsFound = length args

mkQueryMany :: ToRow args => [args] -> Text -> Query
mkQueryMany args q = Query $ Text.unwords $
  ["BEGIN TRAN;"] ++
  fmap asQuery args ++
  ["COMMIT TRAN;"]
  where
  asQuery a = txt <> ";"
    where Query txt = mkQuery a q

interleave :: [a] -> [a] -> [a]
interleave [] ys = ys
interleave xs [] = xs
interleave (x:xs) (y:ys) = x : y : interleave xs ys

query :: FromRow a => Connection -> Query -> IO [a]
query conn q = queryWith rowParser conn q

execute :: Connection -> Query -> IO ()
execute (Connection run) (Query q) =
  annotateWith (\(_:: M.QueryError) -> Text.unpack q) $
  run $ \conn -> M.sql conn q

queryWith :: RowParser a -> Connection -> Query -> IO [a]
queryWith parser (Connection run) (Query q) =
  annotateWith (\(_:: M.QueryError) -> Text.unpack q) $ do
  rows <- run $ \conn -> M.sql conn q
  traverse (parseRow parser) rows

parseRow :: RowParser a -> Row -> IO a
parseRow (RowParser parser) row =
  case snd <$> parser row of
    Left (Unexpected err) -> throwIO (ErrorCall err)
    Right v -> return v

newtype Row = Row [Field]

data Field = Field M.MetaColumnData (Maybe LB.ByteString)

instance M.Row Row where
  fromListOfRawBytes rawdata bytes = Row (zipWith Field rawdata bytes)

data ParseFailure = Unexpected String
  deriving (Show)
  deriving anyclass (Exception)

newtype RowParser a = RowParser (Row -> Either ParseFailure (Row, a))

instance Functor RowParser where
  fmap f (RowParser g) = RowParser $ fmap (fmap $ fmap f) g

instance Applicative RowParser where
  pure v = RowParser $ \row -> Right (row, v)
  (RowParser fs) <*> (RowParser vs) = RowParser $ \row -> do
    (row', f) <- fs row
    (row'', v) <- vs row'
    return (row'', f v)

instance Alternative RowParser where
  empty = fail "no parse"
  (RowParser l) <|> (RowParser r) = RowParser $ \row ->
    case l row of
      Right v -> return v
      Left _ -> r row

instance Monad RowParser where
  (RowParser vs) >>= f = RowParser $ \row -> do
    (row', v) <- vs row
    let RowParser g = f v
    x <- g row'
    return x

instance MonadFail RowParser where
  fail str = RowParser $ \_ -> Left (Unexpected str)

class FromRow r where
  rowParser :: RowParser r

newtype FieldParser a = FieldParser
  { unFieldParser :: Field -> Either ParseFailure a
  }

instance Functor FieldParser where
  fmap fun (FieldParser g) = FieldParser $ \x -> fun <$> g x

instance Applicative FieldParser where
  pure v = FieldParser $ \_ -> Right v
  FieldParser pf <*> FieldParser pv =
    FieldParser $ \x -> pf x <*> pv x

instance Monad FieldParser where
  return = pure
  FieldParser pv >>= f = FieldParser $ \x ->
    case pv x of
      Left err -> Left err
      Right v ->
        let FieldParser g = f v
        in g x

instance Alternative FieldParser where
  empty = FieldParser $ \_ -> Left (Unexpected "empty")
  FieldParser f <|> FieldParser g = FieldParser $ \field ->
    case f field of
      Left _ -> g field
      Right v -> pure v

instance MonadFail FieldParser where
  fail str = parseFailure str

class FromField r where
  fieldParser :: FieldParser r

instance FromField a => FromRow (Only a) where
  rowParser = Only <$> parseField

instance (FromField a, FromField b) =>
  FromRow (a,b) where
  rowParser = (,) <$> parseField <*> parseField

instance (FromField a , FromField b, FromField c) =>
    FromRow (a,b,c) where
  rowParser = (,,) <$> parseField <*> parseField <*> parseField

instance (FromField a , FromField b, FromField c, FromField d) =>
    FromRow (a,b,c,d) where
  rowParser = (,,,) <$> parseField <*> parseField <*> parseField <*> parseField

instance (FromField a , FromField b, FromField c, FromField d, FromField e) =>
    FromRow (a,b,c,d,e) where
  rowParser = (,,,,) <$> parseField <*> parseField <*> parseField <*> parseField <*> parseField

instance (FromField a , FromField b, FromField c, FromField d, FromField e, FromField f) =>
    FromRow (a,b,c,d,e,f) where
  rowParser = (,,,,,) <$> parseField <*> parseField <*> parseField <*> parseField <*> parseField <*> parseField

instance {-# OVERLAPPABLE #-} M.Data r => FromField r where
  fieldParser  = do
    Field (M.MetaColumnData _ _ tinfo _ _) mbs <- fieldInfo
    case unsafePerformIO $ try $ evaluate $ M.fromRawBytes tinfo mbs of
      Left (ErrorCall msg) -> FieldParser $ \_ -> Left (Unexpected msg)
      Right v -> return v

rawBytes :: FieldParser LB.ByteString
rawBytes = do
 Field _ mbytes  <- fieldInfo
 case mbytes of
   Nothing -> fail "no bytes"
   Just bs -> return bs

parseField :: FromField r => RowParser r
parseField = parseFieldWith fieldParser

parseFieldWith :: FieldParser a -> RowParser a
parseFieldWith parser = RowParser $ \(Row row) ->
  case row of
    [] -> Left $ Unexpected $ "insufficient values"
    x : row' -> fmap (Row row',) (unFieldParser parser x)

isEndOfRow :: RowParser Bool
isEndOfRow  = RowParser $ \(Row xs) -> Right (Row xs, null xs)

fieldInfo :: FieldParser Field
fieldInfo = FieldParser $ \x -> Right x

parseFailure :: String -> FieldParser a
parseFailure str = FieldParser $ \_ -> Left (Unexpected str)
