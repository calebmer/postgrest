{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE MultiWayIf           #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module PostgREST.PgQuery (
  fromQi
, insertableValue
, wrapQuery
, asJson
, callProc
, unquoted
, operators

-- format functions
, pgFmtLit
, pgFmtIdent
, pgFmtValue
, pgFmtCondition
, pgFmtColumn
, pgFmtJsonPath
, pgFmtTable
, pgFmtField
, pgFmtSelectItem
, pgFmtAsJsonPath

-- query fragments
, sourceSubqueryName
, orderF
, countNoneF
, countAllF
, countF
, locationF
, asCsvF
, asJsonSingleF
, asJsonF
, selectStarF

, StatementT
) where


import qualified Hasql                   as H
import qualified Hasql.Backend           as B
import qualified Hasql.Postgres          as P
import           PostgREST.RangeQuery
import           PostgREST.Types

import           Control.Monad           (join)
import qualified Data.Aeson              as JSON
import qualified Data.ByteString.Char8   as BS
import           Data.Functor
import qualified Data.HashMap.Strict     as H
import qualified Data.List               as L
import           Data.Maybe              (fromMaybe)
import           Data.Monoid
import           Data.Scientific         (FPFormat (..), formatScientific,
                                          isInteger)
import           Data.String.Conversions (cs)
import qualified Data.Text               as T
import           Data.Vector             (empty)
import           Text.Regex.TDFA         ((=~))

import           Prelude
import qualified Data.Map                as M

type PStmt = H.Stmt P.Postgres
instance Monoid PStmt where
  mappend (B.Stmt query params prep) (B.Stmt query' params' prep') =
    B.Stmt (query <> query') (params <> params') (prep && prep')
  mempty = B.Stmt "" empty True
type StatementT = PStmt -> PStmt
data JsonbPath =
    ColIdentifier T.Text
  | KeyIdentifier T.Text
  | SingleArrow JsonbPath JsonbPath
  | DoubleArrow JsonbPath JsonbPath
  deriving (Show)


operators :: [(T.Text, T.Text)]
operators = [
  ("eq", "="),
  ("gte", ">="), -- has to be before gt (parsers)
  ("gt", ">"),
  ("lte", "<="), -- has to be before lt (parsers)
  ("lt", "<"),
  ("neq", "<>"),
  ("like", "like"),
  ("ilike", "ilike"),
  ("in", "in"),
  ("notin", "not in"),
  ("isnot", "is not"), -- has to be before is (parsers)
  ("is", "is"),
  ("@@", "@@"),
  ("@>", "@>"),
  ("<@", "<@")
  ]

operatorsMap :: M.Map T.Text T.Text
operatorsMap = M.fromList operators

asJson :: StatementT
asJson s = s {
  B.stmtTemplate =
    "array_to_json(coalesce(array_agg(row_to_json(t)), '{}'))::character varying from ("
    <> B.stmtTemplate s <> ") t" }

callProc :: QualifiedIdentifier -> JSON.Object -> PStmt
callProc qi params = do
  let args = T.intercalate "," $ map assignment (H.toList params)
  B.Stmt ("select * from " <> fromQi qi <> "(" <> args <> ")") empty True
  where
    assignment (n,v) = pgFmtIdent n <> ":=" <> insertableValue v

whiteList :: T.Text -> T.Text
whiteList val = fromMaybe
  (cs (pgFmtLit val) <> "::unknown ")
  (L.find ((==) . T.toLower $ val) ["null","true","false"])

trimNullChars :: T.Text -> T.Text
trimNullChars = T.takeWhile (/= '\x0')

fromQi :: QualifiedIdentifier -> T.Text
fromQi t = (if s == "" then "" else pgFmtIdent s <> ".") <> pgFmtIdent n
  where
    n = qiName t
    s = qiSchema t

unquoted :: JSON.Value -> T.Text
unquoted (JSON.String t) = t
unquoted (JSON.Number n) =
  cs $ formatScientific Fixed (if isInteger n then Just 0 else Nothing) n
unquoted (JSON.Bool b) = cs . show $ b
unquoted v = cs $ JSON.encode v

insertableText :: T.Text -> T.Text
insertableText = (<> "::unknown") . pgFmtLit

insertableValue :: JSON.Value -> T.Text
insertableValue JSON.Null = "null"
insertableValue v = insertableText $ unquoted v

wrapQuery :: T.Text -> [T.Text] -> T.Text ->  Maybe NonnegRange -> T.Text
wrapQuery source selectColumns returnSelect range =
  withSourceF source <>
  " SELECT " <>
  T.intercalate ", " selectColumns <>
  " " <>
  fromF returnSelect ( limitF range )


-- query fragments
sourceSubqueryName :: T.Text
sourceSubqueryName = "pg_source"

withSourceF :: T.Text -> T.Text
withSourceF s = "WITH " <> sourceSubqueryName <> " AS (" <> s <>")"

countF :: T.Text
countF = "pg_catalog.count(t)"

countAllF :: T.Text
countAllF = "(SELECT pg_catalog.count(1) FROM (SELECT * FROM " <> sourceSubqueryName <> ") a )"

countNoneF :: T.Text
countNoneF = "null"

asJsonF :: T.Text
asJsonF = "array_to_json(array_agg(row_to_json(t)))::character varying"

asJsonSingleF :: T.Text
asJsonSingleF = "string_agg(row_to_json(t)::text, ',')::character varying "

asCsvF :: T.Text
asCsvF = asCsvHeaderF <> " || '\n' || " <> asCsvBodyF

asCsvHeaderF :: T.Text
asCsvHeaderF =
  "(SELECT string_agg(a.k, ',')" <>
  "  FROM (" <>
  "    SELECT json_object_keys(r)::TEXT as k" <>
  "    FROM ( " <>
  "      SELECT row_to_json(hh) as r from " <> sourceSubqueryName <> " as hh limit 1" <>
  "    ) s" <>
  "  ) a" <>
  ")"

asCsvBodyF :: T.Text
asCsvBodyF = "coalesce(string_agg(substring(t::text, 2, length(t::text) - 2), '\n'), '')"

selectStarF :: T.Text
selectStarF = "SELECT * FROM " <> sourceSubqueryName

fromF :: T.Text -> T.Text -> T.Text
fromF sel limit = "FROM (" <> sel <> " " <> limit <> ") t"

limitF :: Maybe NonnegRange -> T.Text
limitF r  = "LIMIT " <> limit <> " OFFSET " <> offset
  where
    limit  = maybe "ALL" (cs . show) $ join $ rangeLimit <$> r
    offset = cs . show $ fromMaybe 0 $ rangeOffset <$> r

locationF :: [T.Text] -> T.Text
locationF pKeys =
    "(" <>
    " WITH s AS (SELECT row_to_json(ss) as r from " <> sourceSubqueryName <> " as ss  limit 1)" <>
    " SELECT string_agg(json_data.key || '=' || coalesce( 'eq.' || json_data.value, 'is.null'), '&')" <>
    " FROM s, json_each_text(s.r) AS json_data" <>
    (
      if null pKeys
      then ""
      else " WHERE json_data.key IN ('" <> T.intercalate "','" pKeys <> "')"
    ) <>
    ")"

orderF :: [OrderTerm] -> T.Text
orderF ts =
  if L.null ts
    then ""
    else "ORDER BY " <> clause
  where
    clause = T.intercalate "," (map queryTerm ts)
    queryTerm :: OrderTerm -> T.Text
    queryTerm t = " "
           <> cs (pgFmtIdent $ otTerm t) <> " "
           <> cs (otDirection t)         <> " "
           <> maybe "" cs (otNullOrder t) <> " "

-- formating functions

pgFmtValue :: T.Text -> T.Text -> T.Text
pgFmtValue opCode val =
 case opCode of
   "like" -> unknownLiteral $ T.map star val
   "ilike" -> unknownLiteral $ T.map star val
   "in" -> "(" <> T.intercalate ", " (map unknownLiteral $ T.split (==',') val) <> ") "
   "notin" -> "(" <> T.intercalate ", " (map unknownLiteral $ T.split (==',') val) <> ") "
   "@@" -> "to_tsquery(" <> unknownLiteral val <> ") "
   _    -> unknownLiteral val
 where
   star c = if c == '*' then '%' else c
   unknownLiteral = (<> "::unknown ") . pgFmtLit

pgFmtOperator :: T.Text -> T.Text
pgFmtOperator opCode = fromMaybe "=" $ M.lookup opCode operatorsMap

pgFmtIdent :: T.Text -> T.Text
pgFmtIdent x =
 let escaped = T.replace "\"" "\"\"" (trimNullChars $ cs x) in
 if (cs escaped :: BS.ByteString) =~ danger
   then "\"" <> escaped <> "\""
   else escaped

 where danger = "^$|^[^a-z_]|[^a-z_0-9]" :: BS.ByteString

pgFmtLit :: T.Text -> T.Text
pgFmtLit x =
 let trimmed = trimNullChars x
     escaped = "'" <> T.replace "'" "''" trimmed <> "'"
     slashed = T.replace "\\" "\\\\" escaped in
 if T.isInfixOf "\\\\" escaped
   then "E" <> slashed
   else slashed

pgFmtCondition :: QualifiedIdentifier -> Filter -> T.Text
pgFmtCondition table (Filter (col,jp) ops val) =
  notOp <> " " <> sqlCol  <> " " <> pgFmtOperator opCode <> " " <>
    if opCode `elem` ["is","isnot"] then whiteList (getInner val) else sqlValue
  where
    headPredicate:rest = T.split (=='.') ops
    hasNot caseTrue caseFalse = if headPredicate == "not" then caseTrue else caseFalse
    opCode      = hasNot (head rest) headPredicate
    notOp       = hasNot headPredicate ""
    sqlCol = case val of
      VText _ -> pgFmtColumn table col <> pgFmtJsonPath jp
      VForeignKey qi _ -> pgFmtColumn qi col
    sqlValue = valToStr val
    getInner v = case v of
      VText s -> s
      _      -> ""
    valToStr v = case v of
      VText s -> pgFmtValue opCode s
      VForeignKey (QualifiedIdentifier s _) (ForeignKey Column{colTable=Table{tableName=ft}, colName=fc}) -> pgFmtColumn qi fc
        where qi = QualifiedIdentifier (if ft == sourceSubqueryName then "" else s) ft
      _ -> ""

pgFmtColumn :: QualifiedIdentifier -> T.Text -> T.Text
pgFmtColumn table "*" = fromQi table <> ".*"
pgFmtColumn table c = fromQi table <> "." <> pgFmtIdent c

pgFmtJsonPath :: Maybe JsonPath -> T.Text
pgFmtJsonPath (Just [x]) = "->>" <> pgFmtLit x
pgFmtJsonPath (Just (x:xs)) = "->" <> pgFmtLit x <> pgFmtJsonPath ( Just xs )
pgFmtJsonPath _ = ""

pgFmtTable :: Table -> T.Text
pgFmtTable Table{tableSchema=s, tableName=n} = fromQi $ QualifiedIdentifier s n

pgFmtField :: QualifiedIdentifier -> Field -> T.Text
pgFmtField table (c, jp) = pgFmtColumn table c <> pgFmtJsonPath jp

pgFmtSelectItem :: QualifiedIdentifier -> SelectItem -> T.Text
pgFmtSelectItem table (f@(_, jp), Nothing) = pgFmtField table f <> pgFmtAsJsonPath jp
pgFmtSelectItem table (f@(_, jp), Just cast ) = "CAST (" <> pgFmtField table f <> " AS " <> cast <> " )" <> pgFmtAsJsonPath jp

pgFmtAsJsonPath :: Maybe JsonPath -> T.Text
pgFmtAsJsonPath Nothing = ""
pgFmtAsJsonPath (Just xx) = " AS " <> last xx
