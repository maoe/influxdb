{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns #-}
module Database.InfluxDB.Write
  ( -- * Writers
    write
  , writeBatch
  , writeByteString

  -- * Writer parameters
  , WriteParams
  , writeParams
  , Types.server
  , Types.database
  , retentionPolicy
  , Types.precision
  , Types.manager
) where
import Control.Exception
import Control.Monad
import Data.Maybe

import Control.Lens
import qualified Data.Aeson as A
import qualified Data.Aeson.Types as A
import qualified Data.ByteString.Char8 as B8
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text.Encoding as TE
import qualified Network.HTTP.Types as HT

import Database.InfluxDB.Line
import Database.InfluxDB.Types as Types
import Database.InfluxDB.JSON
import qualified Network.HTTP.Client.Compat as HC

-- | The full set of parameters for the HTTP writer.
data WriteParams = WriteParams
  { _server :: !Server
  , _database :: !Database
  -- ^ Database to be written
  , _retentionPolicy :: !(Maybe Key)
  -- ^ 'Nothing' means the default retention policy for the database.
  , _precision :: !(Precision 'WriteRequest)
  -- ^ Timestamp precision
  --
  -- In the HTTP API, timestamps are scaled by the given precision.
  , _authentication  :: !(Maybe Credentials)
  -- ^ No authentication by default
  , _manager :: !(Either HC.ManagerSettings HC.Manager)
  -- ^ HTTP connection manager
  }

-- | Smart constructor for 'WriteParams'
--
-- Default parameters:
--
--   ['L.server'] 'localServer'
--   ['L.precision'] 'Nanosecond'
--   ['retentionPolicy'] 'Nothing'
--   ['L.manager'] @'Left' 'HC.defaultManagerSettings'@
writeParams :: Database -> WriteParams
writeParams _database = WriteParams
  { _server = localServer
  , _precision = Nanosecond
  , _retentionPolicy = Nothing
  , _authentication = Nothing
  , _manager = Left HC.defaultManagerSettings
  , ..
  }

-- | Write a 'Line'
write
  :: Timestamp time
  => WriteParams
  -> Line time
  -> IO ()
write p@WriteParams {_precision} =
  writeByteString p . encodeLine (scaleTo _precision)

-- | Write 'Line's in a batch
--
-- This is more efficient than 'write'.
writeBatch
  :: (Timestamp time, Traversable f)
  => WriteParams
  -> f (Line time)
  -> IO ()
writeBatch p@WriteParams {_precision} =
  writeByteString p . encodeLines (scaleTo _precision)

-- | Write a raw 'BL.ByteString'
writeByteString :: WriteParams -> BL.ByteString -> IO ()
writeByteString params payload = do
  manager' <- either HC.newManager return $ _manager params
  response <- HC.httpLbs request manager'
  let body = HC.responseBody response
      status = HC.responseStatus response
  if BL.null body
    then do
      let message = B8.unpack $ HT.statusMessage status
      when (HT.statusIsServerError status) $
        throwIO $ ServerError message
      when (HT.statusIsClientError status) $
        throwIO $ BadRequest message request
    else case A.eitherDecode' body of
      Left message ->
        throwIO $ IllformedJSON message body
      Right val -> case A.parse parseErrorObject val of
        A.Success _ ->
          fail $ "BUG: impossible code path in Database.InfluxDB.Write.writeByteString"
        A.Error message -> do
          when (HT.statusIsServerError status) $
            throwIO $ ServerError message
          when (HT.statusIsClientError status) $
            throwIO $ BadRequest message request
          fail $ "BUG: " ++ message
            ++ " in Database.InfluxDB.Write.writeByteString"

  where
    request = (writeRequest params)
      { HC.requestBody = HC.RequestBodyLBS payload
      }

writeRequest :: WriteParams -> HC.Request
writeRequest WriteParams {..} =
  HC.setQueryString qs HC.defaultRequest
    { HC.host = TE.encodeUtf8 _host
    , HC.port = fromIntegral _port
    , HC.secure = _ssl
    , HC.method = "POST"
    , HC.path = "/write"
    }
  where
    Server {..} = _server
    qs = concat
      [ [("db", Just $ TE.encodeUtf8 $ databaseName _database)]
      , fromMaybe [] $ do
        Key name <- _retentionPolicy
        return [("rp", Just (TE.encodeUtf8 name))]
      , fromMaybe [] $ do
        Credentials { _user = u, _password = p } <- _authentication
        return
          [ ("u", Just (TE.encodeUtf8 u))
          , ("p", Just (TE.encodeUtf8 p))
          ]
      ]

makeLensesWith (lensRules & generateSignatures .~ False) ''WriteParams

server :: Lens' WriteParams Server

-- |
-- >>> let p = writeParams "foo"
-- >>> p ^. server.host
-- "localhost"
instance HasServer WriteParams where
  server = Database.InfluxDB.Write.server

database :: Lens' WriteParams Database

-- |
-- >>> let p = writeParams "foo"
-- >>> p ^. database
-- "foo"
instance HasDatabase WriteParams where
  database = Database.InfluxDB.Write.database

-- | Target retention policy for the write.
--
-- InfluxDB writes to the @default@ retention policy if this parameter is set
-- to 'Nothing'.
--
-- >>> let p = writeParams "foo"
-- >>> let p' = p & retentionPolicy .~ Just "two_hours"
-- >>> p' ^. retentionPolicy
-- Just "two_hours"
retentionPolicy :: Lens' WriteParams (Maybe Key)

precision :: Lens' WriteParams (Precision 'WriteRequest)

-- |
-- >>> let p = writeParams "foo"
-- >>> p ^. precision
-- Nanosecond
instance HasPrecision 'WriteRequest WriteParams where
  precision = Database.InfluxDB.Write.precision

manager :: Lens' WriteParams (Either HC.ManagerSettings HC.Manager)

-- |
-- >>> let p = writeParams "foo"
-- >>> p & manager .~ Left HC.defaultManagerSettings
instance HasManager WriteParams where
  manager = Database.InfluxDB.Write.manager

-- | Authentication info for the write
--
-- >>> let p = writeParams "foo"
-- >>> p ^. authentication
-- Nothing
authentication :: Lens' WriteParams (Maybe Credentials)

instance HasCredentials WriteParams where
  authentication = Database.InfluxDB.Write.authentication
