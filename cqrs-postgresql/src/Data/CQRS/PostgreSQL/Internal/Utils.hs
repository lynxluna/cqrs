{-# LANGUAGE BangPatterns, DeriveGeneric, OverloadedStrings, GeneralizedNewtypeDeriving #-}
module Data.CQRS.PostgreSQL.Internal.Utils
       ( SqlValue(..)
       , Transaction
       , QueryError(..)
       , badQueryResultMsg
       , execSql
       , execSql'
       , query
       , isDuplicateKey
       , runQuery         -- For test use only
       , runTransaction
       , runTransactionP
       ) where

import           Control.Exception (Exception, throw)
import           Control.Exception.Enclosed (catchAny)
import           Control.Monad (forM, void)
import           Control.Monad.IO.Class (liftIO, MonadIO)
import           Control.Monad.Trans.Class (lift)
import           Control.Monad.Trans.Reader (ReaderT, runReaderT, ask)
import           Control.Exception (SomeException)
import qualified Data.ByteString.Char8 as B8
import           Data.ByteString (ByteString)
import           Data.ByteString.Lex.Integral (readDecimal)
import           Data.Int (Int16, Int32, Int64)
import           Data.Pool (Pool, withResource)
import           Data.Text (Text)
import           Data.Text.Encoding (decodeUtf8', encodeUtf8)
import           Data.Typeable (Typeable)
import           Database.PostgreSQL.LibPQ (Connection, Oid(..), Format(..), ExecStatus(..), Column(..), Row(..), FieldCode(..))
import qualified Database.PostgreSQL.LibPQ as P
import           GHC.Generics (Generic)
import           System.IO.Streams (InputStream)
import qualified System.IO.Streams.Combinators as SC
import qualified System.IO.Streams.List as SL

-- | Known field types.
data SqlValue = SqlByteArray (Maybe ByteString)
              | SqlBlankPaddedString (Maybe ByteString)
              | SqlBool (Maybe Bool)
              | SqlInt16 (Maybe Int16)
              | SqlInt32 (Maybe Int32)
              | SqlInt64 (Maybe Int64)
              | SqlVarChar (Maybe Text)
              | SqlText (Maybe Text)
              | Unmatched (Oid, Maybe ByteString)
              deriving (Eq, Show)

-- | Is the given query exception a duplicate key exception?
isDuplicateKey :: QueryError -> Maybe ()
isDuplicateKey qe | qeSqlState qe == Just "23505" = Just ()
                  | otherwise                     = Nothing

-- | Transaction in PostgreSQL.
newtype Transaction a = Transaction (ReaderT Connection IO a)
  deriving (Functor, Applicative, Monad, MonadIO)

-- | Run transaction
runTransaction :: Connection -> Transaction a -> IO a
runTransaction connection transaction = do
  begin
  catchAny runAction tryRollback
  where
    runAction = do
      r <- doRunTransaction connection transaction
      commit
      return r

    tryRollback :: SomeException -> IO a
    tryRollback e =
      -- Try explicit rollback; we want to preserve original exception.
      catchAny (rollback >> throw e) $ \_ ->
          -- Rethrow original exception; resource pool will make sure the database
          -- connection is properly destroyed (rather than being returned to the
          -- pool).
          throw e

    begin = run "START TRANSACTION;" [ ]
    commit = run "COMMIT TRANSACTION;" [ ]
    rollback = run "ROLLBACK TRANSACTION;" [ ]

    run sql parameters =
      queryImpl connection sql parameters (\_ _ -> return ())

-- | Perform the actions inside a Transaction on a connection WITHOUT
-- wrapping in any TRANSACTION statements.
doRunTransaction :: Connection -> Transaction a -> IO a
doRunTransaction connection (Transaction t) = do
  runReaderT t connection

-- | Run a transaction with a connection from the given resource pool
-- and return the connection when the transaction ends.
runTransactionP :: Pool Connection -> Transaction a -> IO a
runTransactionP pool action = withResource pool $ (flip runTransaction) action

-- | Read a boolean.
readBoolean :: ByteString -> Maybe Bool
readBoolean "t" = Just True
readBoolean "f" = Just False
readBoolean _ = Nothing

-- | Map an SqlValue to a parameter.
fromSqlValue :: Connection -> SqlValue -> IO (Maybe (Oid, ByteString, Format))
fromSqlValue connection (SqlByteArray a) = do
  case a of
    Nothing -> return Nothing
    Just a' -> do
      x <- P.escapeByteaConn connection a'
      case x of
        Nothing -> error "Conversion failed"
        Just x' -> return $ Just (Oid 17, x', Text)
fromSqlValue _ (SqlBool (Just True)) = return $ Just (Oid 16, "t", Text)
fromSqlValue _ (SqlBool (Just False)) = return $ Just (Oid 16, "f", Text)
fromSqlValue _ (SqlBool Nothing) = return Nothing
fromSqlValue _ (SqlInt32 Nothing) = return Nothing
fromSqlValue _ (SqlInt32 (Just i)) = return $ Just (Oid 23, B8.pack (show i), Text)
fromSqlValue _ (SqlInt64 Nothing) = return Nothing
fromSqlValue _ (SqlInt64 (Just i)) = return $ Just (Oid 20, B8.pack (show i), Text)
fromSqlValue _ (SqlVarChar Nothing) = return Nothing
fromSqlValue _ (SqlVarChar (Just t)) = return $ Just (Oid 1043, encodeUtf8 t, Binary)
fromSqlValue _ (SqlText Nothing) = return Nothing
fromSqlValue _ (SqlText (Just t)) = return $ Just (Oid 25, encodeUtf8 t, Text)
fromSqlValue _ _ = error "fromSqlValue: Parameter conversion failed"

-- | Map field to an SqlValue.
toSqlValue :: (Oid, Maybe ByteString) -> IO SqlValue
toSqlValue (oid, mvalue) =
  case oid of
    Oid 17 -> c P.unescapeBytea SqlByteArray
    Oid 16 -> c (return . readBoolean) SqlBool
    Oid 20 -> c (return . fmap fst . readDecimal) SqlInt64
    Oid 21 -> c (return . fmap fst . readDecimal) SqlInt16
    Oid 23 -> c (return . fmap fst . readDecimal) SqlInt32
    Oid 25 -> c (return . either (const Nothing) Just . decodeUtf8') SqlText
    Oid 1042 -> c (return . Just) SqlBlankPaddedString
    Oid 1043 -> c (return . either (const Nothing) Just . decodeUtf8') SqlVarChar

    _ -> return $ Unmatched (oid,mvalue)
  where
    c :: Monad m => (ByteString -> m (Maybe a)) -> (Maybe a -> SqlValue) -> m SqlValue
    c convert construct =
      case mvalue of
        Nothing -> return $ construct Nothing
        Just value -> do
          mvalue' <- convert value
          case mvalue' of
            Nothing -> error "toSqlValue: Conversion failed"
            Just _  -> return $ construct mvalue'

-- | Execute a query with no result.
execSql :: Text -> [SqlValue] -> Transaction ()
execSql sql parameters = void $ execSql' sql parameters

-- | Execute a query an return the number of updated rows (if available).
execSql' :: Text -> [SqlValue] -> Transaction (Maybe Int)
execSql' sql parameters = query' sql parameters (\n _ -> return n)

-- | Error happened during query.
data QueryError = QueryError
    { qeSqlState :: Maybe ByteString
    , qeStatusMessage :: ByteString
    , qeErrorMessage :: Maybe ByteString
    } deriving (Show, Typeable, Generic)

instance Exception QueryError

-- | Run a query and fold over the results. The action receives an
-- 'InputStream' over all the rows in the result.
query :: Text -> [SqlValue] -> (InputStream [SqlValue] -> Transaction a) -> Transaction a
query sql parameters f = query' sql parameters $ \_ is -> f is

query' :: Text -> [SqlValue] -> (Maybe Int -> InputStream [SqlValue] -> Transaction a) -> Transaction a
query' sql parameters f = Transaction $ do
  connection <- ask
  lift $ queryImpl connection sql parameters (\n is -> doRunTransaction connection (f n is))

queryImpl :: Connection -> Text -> [SqlValue] -> (Maybe Int -> InputStream [SqlValue] -> IO a) -> IO a
queryImpl connection sql parameters f = do
  -- Run the query
  r <- open
  -- Check the status
  status <- P.resultStatus r
  if isOk status
    then do
      -- How many rows affected?
      cmdTuples <- P.cmdTuples r
      n <- case cmdTuples of
        Nothing -> return Nothing
        Just x -> return $ fmap fst $ readDecimal x
      -- Create the input stream and feed it to 'f'
      makeInputStream r >>= f n
    else do
      -- Throw exception
      sqlState <- P.resultErrorField r DiagSqlstate
      statusMessage <- P.resStatus status
      errorMessage <- P.resultErrorMessage r
      throw $ QueryError { qeSqlState = sqlState
                         , qeStatusMessage = statusMessage
                         , qeErrorMessage = errorMessage
                         }

  where
    isOk CommandOk = True
    isOk TuplesOk  = True
    isOk _         = False

    open = do
      parameters' <- forM parameters $ fromSqlValue connection
      mr <- P.execParams connection (encodeUtf8 sql) parameters' Text
      case mr of
        Nothing -> error "No result set; something is very wrong"
        Just r -> return r

    makeInputStream r = do
      Col nFields <- P.nfields r
      Row nRows <- P.ntuples r
      let columns = map P.toColumn [0.. nFields - 1]
      let loop i = if i >= nRows
                     then do
                       return Nothing
                     else do
                       columnValues <- forM columns $ getSqlVal r $ P.toRow i
                       return $ Just (columnValues, i + 1)
      SC.unfoldM loop 0

    getSqlVal r row c = do
      mval <- P.getvalue' r row c
      typ <- P.ftype r c
      toSqlValue (typ, mval)

-- Run a query and result a list of the rows in the result.
runQuery :: Text -> [SqlValue] -> Transaction [[SqlValue]]
runQuery sql parameters = query sql parameters (liftIO . SL.toList)

-- | Format a message indicating a bad query result due to the "shape".
badQueryResultMsg :: [String] -> [SqlValue] -> String
badQueryResultMsg params columns = concat ["Invalid query result shape. Params: ", show params, ". Result columns: ", show columns]
