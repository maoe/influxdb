{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
module Database.InfluxDB.Line
  ( Line(Line)
  , measurement
  , tagSet
  , fieldSet
  , timestamp

  , buildLine
  , buildLines
  , encodeLine
  , encodeLines
  ) where
import Data.List (intersperse)
import Data.Int (Int64)
import Data.Monoid

import Control.DeepSeq
import Control.Lens
import Data.Map (Map)
import Data.Text (Text)
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as L
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics

import Database.InfluxDB.Types

-- | Placeholder for the Line Protocol
--
-- See https://docs.influxdata.com/influxdb/v1.0/write_protocols/line_protocol_tutorial/ for the
-- concrete syntax.
data Line time = Line
  { _measurement :: !Key
  -- ^ Measurement name
  , _tagSet :: !(Map Key Text)
  -- ^ Set of tags (optional)
  , _fieldSet :: !(Map Key FieldValue)
  -- ^ Set of fields
  --
  -- It shouldn't be empty.
  , _timestamp :: !(Maybe time)
  -- ^ Timestamp (optional)
  } deriving (Generic, NFData)

encodeLine
  :: (time -> Int64)
  -> Line time
  -> L.ByteString
encodeLine toTimestamp = B.toLazyByteString . buildLine toTimestamp

encodeLines
  :: Traversable f
  => (time -> Int64)
  -> f (Line time)
  -> L.ByteString
encodeLines toTimestamp = B.toLazyByteString . buildLines toTimestamp

buildLine
  :: (time -> Int64)
  -> Line time
  -> B.Builder
buildLine toTimestamp Line {..} =
  key <> " " <> fields <> maybe "" (" " <>) timestamp
  where
    measurement = buildKey _measurement
    tags = buildMap TE.encodeUtf8Builder _tagSet
    key = if Map.null _tagSet
      then measurement
      else measurement <> "," <> tags
    fields = buildMap buildFieldValue _fieldSet
    timestamp = B.int64Dec . toTimestamp <$> _timestamp
    buildMap encodeVal =
      mconcat . intersperse "," . map encodeKeyVal . Map.toList
      where
        encodeKeyVal (name, val) = mconcat
          [ buildKey name
          , "="
          , encodeVal val
          ]

buildKey :: Key -> B.Builder
buildKey = TE.encodeUtf8Builder . escapeKey

escapeKey :: Key -> Text
escapeKey (Key text) = T.replace " " "\\ " $ T.replace "," "\\," text

buildFieldValue :: FieldValue -> B.Builder
buildFieldValue = \case
  FieldInt i -> B.int64Dec i <> "i"
  FieldFloat d -> B.doubleDec d
  FieldString t -> "\"" <> TE.encodeUtf8Builder t <> "\""
  FieldBool b -> if b then "true" else "false"
  FieldNull -> "null"

buildLines
  :: Traversable f
  => (time -> Int64)
  -> f (Line time)
  -> B.Builder
buildLines toTimestamp = foldMap ((<> "\n") . buildLine toTimestamp)

makeLensesWith (lensRules & generateSignatures .~ False) ''Line

-- | Name of the measurement that you want to write your data to.
measurement :: Lens' (Line time) Key

-- | Tag(s) that you want to include with your data point. Tags are optional in
-- the Line Protocol, so you can set it 'empty'.
tagSet :: Lens' (Line time) (Map Key Text)

-- | Field(s) for your data point. Every data point requires at least one field
-- in the Line Protocol, so it shouldn't be 'empty'.
fieldSet :: Lens' (Line time) (Map Key FieldValue)

-- | Timestamp for your data point. You can put whatever type of timestamp that
-- is an instance of the 'Timestamp' class.
timestamp :: Lens' (Line time) (Maybe time)
