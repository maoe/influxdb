{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
module Database.InfluxDB.Types where
import Control.Exception
import Data.Int (Int64)
import Data.String
import Data.Typeable (Typeable)
import GHC.Generics (Generic)

import Lens.Micro
import Lens.Micro.TH
import Data.Text (Text)
import Data.Time.Clock
import Data.Time.Clock.POSIX
import Network.HTTP.Client (Manager, ManagerSettings, Request)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Network.HTTP.Client as HC

-- $setup
-- >>> :set -XOverloadedStrings
-- >>> import Database.InfluxDB

-- | An InfluxDB query.
--
-- A spec of the format is available at
-- <https://docs.influxdata.com/influxdb/v1.2/query_language/spec/>.
--
-- A 'Query' can be constructed using either
--
--   * the 'IsString' instance with @-XOverloadedStrings@
--   * or 'Database.InfluxDB.Format.formatQuery'.
--
-- >>> :set -XOverloadedStrings
-- >>> "SELECT * FROM series" :: Query
-- "SELECT * FROM series"
-- >>> import qualified Database.InfluxDB.Format as F
-- >>> formatQuery ("SELECT * FROM "%F.key) "series"
-- "SELECT * FROM \"series\""
--
-- NOTE: Currently this library doesn't support type-safe query construction.
newtype Query = Query T.Text deriving IsString

instance Show Query where
  show (Query q) = show q

data Server = Server
  { _host :: !Text
  , _port :: !Int
  , _ssl :: !Bool
  } deriving (Show, Generic, Eq, Ord)

-- | Default server settings.
--
-- Default parameters:
--
--  * 'host': @"localhost"@
--  * 'port': @8086@
--  * 'ssl': 'False'
defaultServer :: Server
defaultServer = Server
  { _host = "localhost"
  , _port = 8086
  , _ssl = False
  }

makeLensesWith (lensRules & generateSignatures .~ False) ''Server

-- | Host name of the server
host :: Lens' Server Text

-- | Port number of the server
port :: Lens' Server Int

-- | If SSL is enabled
ssl :: Lens' Server Bool

-- | User credentials
data Credentials = Credentials
  { _user :: !Text
  , _password :: !Text
  } deriving Show

credentials
    :: Text -- ^ User name
    -> Text -- ^ Password
    -> Credentials
credentials = Credentials

makeLensesWith (lensRules & generateSignatures .~ False) ''Credentials

-- | User name to access InfluxDB.
--
-- >>> let creds = credentials "john" "passw0rd"
-- >>> creds ^. user
-- "john"
user :: Lens' Credentials Text

-- | Password to access InfluxDB
password :: Lens' Credentials Text

-- | Database name.
--
-- 'Database.InfluxDB.formatDatabase' can be used to construct a
-- 'Database'.
newtype Database = Database { databaseName :: Text } deriving (Eq, Ord)

-- | String type that is used for measurements, tag keys and field keys.
--
-- 'Database.InfluxDB.formatKey' can be used to construct a 'Key'.
newtype Key = Key Text deriving (Eq, Ord)

instance IsString Database where
  fromString xs = Database $ fromNonEmptyString "Database" xs

instance IsString Key where
  fromString xs = Key $ fromNonEmptyString "Key" xs

fromNonEmptyString :: String -> String -> Text
fromNonEmptyString ty xs
  | null xs = error $ ty ++ " should never be empty"
  | otherwise = fromString xs

instance Show Database where
  show (Database name) = show name

instance Show Key where
  show (Key name) = show name

data Nullability = Nullable | NonNullable deriving Typeable

-- | Field type for queries. Queries can contain null values.
type QueryField = Field 'Nullable

-- | Field type for the line protocol. The line protocol doesn't accept null
-- values.
type LineField = Field 'NonNullable

data Field (n :: Nullability) where
  FieldInt :: !Int64 -> Field n
  FieldFloat :: !Double -> Field n
  FieldString :: !Text -> Field n
  FieldBool :: !Bool -> Field n
  FieldNull :: Field 'Nullable
  deriving Typeable

deriving instance Eq (Field n)
deriving instance Show (Field n)

instance IsString (Field n) where
  fromString = FieldString . T.pack

-- | Type of a request
data RequestType
  = QueryRequest
  -- ^ Request for @/query@
  | WriteRequest
  -- ^ Request for @/write@
  deriving Show

-- | Predefined set of time precision.
--
-- 'RFC3339' is only available for 'QueryRequest's.
data Precision (ty :: RequestType) where
  -- | POSIX time in ns
  Nanosecond :: Precision ty
  -- | POSIX time in μs
  Microsecond :: Precision ty
  -- | POSIX time in ms
  Millisecond :: Precision ty
  -- | POSIX time in s
  Second :: Precision ty
  -- | POSIX time in minutes
  Minute :: Precision ty
  -- | POSIX time in hours
  Hour :: Precision ty
  -- | Nanosecond precision time in a human readable format, like
  -- @2016-01-04T00:00:23.135623Z@. This is the default format for @/query@.
  RFC3339 :: Precision 'QueryRequest

deriving instance Show (Precision a)

-- | Name of the time precision.
--
-- >>> precisionName Nanosecond
-- "n"
precisionName :: Precision ty -> Text
precisionName = \case
  Nanosecond -> "n"
  Microsecond -> "u"
  Millisecond -> "ms"
  Second -> "s"
  Minute -> "m"
  Hour -> "h"
  RFC3339 -> "rfc3339"

-- | A 'Timestamp' is something that can be converted to a valid
-- InfluxDB timestamp, which is represented as a 64-bit integer.
class Timestamp time where
  -- | Round a time to the given precision and scale it to nanoseconds
  roundTo :: Precision 'WriteRequest -> time -> Int64
  -- | Scale a time to the given precision
  scaleTo :: Precision 'WriteRequest -> time -> Int64

roundAt :: RealFrac a => a -> a -> a
roundAt scale x = fromIntegral (round (x / scale) :: Int) * scale

-- | Scale of the type precision.
--
-- >>> precisionScale RFC3339
-- 1.0e-9
-- >>> precisionScale Microsecond
-- 1.0e-6
precisionScale :: Fractional a => Precision ty -> a
precisionScale = \case
  RFC3339 ->     10^^(-9 :: Int)
  Nanosecond ->  10^^(-9 :: Int)
  Microsecond -> 10^^(-6 :: Int)
  Millisecond -> 10^^(-3 :: Int)
  Second -> 1
  Minute -> 60
  Hour ->   60 * 60

instance Timestamp UTCTime where
  roundTo prec = roundTo prec . utcTimeToPOSIXSeconds
  scaleTo prec = scaleTo prec . utcTimeToPOSIXSeconds

instance Timestamp NominalDiffTime where
  roundTo prec time =
    round $ 10^(9 :: Int) * roundAt (precisionScale prec) time
  scaleTo prec time = round $ time / precisionScale prec

-- | Exceptions used in this library.
--
-- In general, the library tries to convert exceptions from the dependent
-- libraries to the following types of errors.
data InfluxException
  = ServerError String
  -- ^ Server side error.
  --
  -- You can expect to get a successful response once the issue is resolved on
  -- the server side.
  | ClientError String Request
  -- ^ Client side error.
  --
  -- You need to fix your query to get a successful response.
  | UnexpectedResponse String BL.ByteString
  -- ^ Received an unexpected response. The 'String' field is a message and the
  -- 'BL.ByteString' field is a possibly-empty relevant payload.
  --
  -- This can happen e.g. when the response from InfluxDB is incompatible with
  -- what this library expects due to an upstream format change etc.
  | HTTPException HC.HttpException
  -- ^ HTTP communication error.
  --
  -- Typical HTTP errors (4xx and 5xx) are covered by 'ClientError' and
  -- 'ServerError'. So this exception means something unusual happened. Note
  -- that if 'HC.checkResponse' is overridden to throw an 'HC.HttpException' on
  -- an unsuccessful HTTP code, this exception is thrown instead of
  -- 'ClientError' or 'ServerError'.
  deriving (Show, Typeable)

instance Exception InfluxException

class HasServer a where
  -- | InfluxDB server address and port that to interact with.
  server :: Lens' a Server

class HasDatabase a where
  -- | Database name to work on.
  database :: Lens' a Database

class HasPrecision (ty :: RequestType) a | a -> ty where
  -- | Time precision parameter.
  precision :: Lens' a (Precision ty)

class HasManager a where
  -- | HTTP manager settings or a manager itself.
  --
  -- If it's set to 'ManagerSettings', the library will create a 'Manager' from
  -- the settings for you.
  manager :: Lens' a (Either ManagerSettings Manager)

class HasCredentials a where
  -- | User name and password to be used when sending requests to InfluxDB.
  authentication :: Lens' a (Maybe Credentials)
