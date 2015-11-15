{-# LANGUAGE TupleSections #-}
module PostgREST.QueryBuilder
where


import           Control.Error
import           Data.List         (find)
import           Data.Monoid
import           Data.Text         hiding (filter, find, foldr, head, last, map,
                                    null, zipWith, concatMap)
import           Control.Applicative
import           Data.Tree
import           PostgREST.PgQuery (fromQi, pgFmtCondition, pgFmtSelectItem,
                                    pgFmtIdent, pgFmtCondition,
                                    insertableValue, orderF, sourceSubqueryName, pgFmtJsonPath)
import           PostgREST.Types
import qualified Data.Map as M

findRelation :: [Relation] -> Schema -> Text -> Text -> Maybe Relation
findRelation allRelations s t1 t2 =
  find (\r -> s == (tableSchema . relTable) r && t1 == (tableName . relTable) r && t2 == (tableName . relFTable) r) allRelations

addRelations :: Schema -> [Relation] -> Maybe ApiRequest -> ApiRequest -> Either Text ApiRequest
addRelations schema allRelations parentNode node@(Node n@(query, (table, _)) forest) =
  case parentNode of
    Nothing -> Node (query, (table, Nothing)) <$> updatedForest
    (Just (Node (_, (parentTable, _)) _)) -> Node <$> (addRel n <$> rel) <*> updatedForest
      where
        rel = note ("no relation between " <> table <> " and " <> parentTable)
            $  findRelation allRelations schema table parentTable
           <|> findRelation allRelations schema parentTable table
        addRel :: (Query, (NodeName, Maybe Relation)) -> Relation -> (Query, (NodeName, Maybe Relation))
        addRel (q, (t, _)) r = (q, (t, Just r))
  where
    updatedForest = mapM (addRelations schema allRelations (Just node)) forest

getJoinConditions :: Relation -> [Filter]
getJoinConditions (Relation t cs ft fcs typ lt lc1 lc2) =
  case typ of
    Child  -> zipWith (toFilter tN ftN) cs fcs
    Parent -> zipWith (toFilter tN ftN) cs fcs
    Many   -> zipWith (toFilter tN ltN) cs (fromMaybe [] lc1) ++ zipWith (toFilter ftN ltN) fcs (fromMaybe [] lc2)
  where
    s = tableSchema t
    tN = tableName t
    ftN = tableName ft
    ltN = fromMaybe "" (tableName <$> lt)
    toFilter :: Text -> Text -> Column -> Column -> Filter
    toFilter tb ftb c fc = Filter (colName c, Nothing) "=" (VForeignKey (QualifiedIdentifier s tb) (ForeignKey fc{colTable=(colTable fc){tableName=ftb}}))

addJoinConditions :: Text -> ApiRequest -> Either Text ApiRequest
addJoinConditions schema (Node (query, (n, r)) forest) =
  case r of
    Nothing -> Node (updatedQuery, (n,r))  <$> updatedForest -- this is the root node
    Just rel@(Relation{relType=Child}) -> Node (addCond updatedQuery (getJoinConditions rel),(n,r)) <$> updatedForest
    Just (Relation{relType=Parent}) -> Node (updatedQuery, (n,r)) <$> updatedForest
    Just rel@(Relation{relType=Many, relLTable=(Just linkTable)}) ->
      Node (qq, (n, r)) <$> updatedForest
      where
         q = addCond updatedQuery (getJoinConditions rel)
         qq = q{from=tableName linkTable : from q}
    _ -> Left "unknown relation"
  where
    -- add parentTable and parentJoinConditions to the query
    updatedQuery = foldr (flip addCond) (query{from = parentTables ++ from query}) parentJoinConditions
      where
        parentJoinConditions = map (getJoinConditions . snd) parents
        parentTables = map fst parents
        parents = mapMaybe (getParents . rootLabel) forest
        getParents (_, (tbl, Just rel@(Relation{relType=Parent}))) = Just (tbl, rel)
        getParents _ = Nothing
    updatedForest = mapM (addJoinConditions schema) forest
    addCond q con = q{where_=con ++ where_ q}

emptyOnNull :: Text -> [a] -> Text
emptyOnNull val x = if null x then "" else val

requestToQuery :: Text -> ApiRequest -> Text
requestToQuery schema (Node (Select colSelects tbls conditions ord, (mainTbl, _)) forest) =
  query
  where
    -- TODO! the folloing helper functions are just to remove the "schema" part when the table is "source" which is the name
    -- of our WITH query part
    tblSchema tbl = if tbl == sourceSubqueryName then "" else schema
    qi = QualifiedIdentifier (tblSchema mainTbl) mainTbl
    toQi t = QualifiedIdentifier (tblSchema t) t
    query = Data.Text.unwords [
      ("WITH " <> intercalate ", " withs) `emptyOnNull` withs,
      "SELECT ", intercalate ", " (map (pgFmtSelectItem qi) colSelects ++ selects),
      "FROM ", intercalate ", " (map (fromQi . toQi) tbls),
      ("WHERE " <> intercalate " AND " ( map (pgFmtCondition qi ) conditions )) `emptyOnNull` conditions,
      orderF (fromMaybe [] ord)
      ]
    (withs, selects) = foldr getQueryParts ([],[]) forest
    getQueryParts :: Tree ApiNode -> ([Text], [Text]) -> ([Text], [Text])
    getQueryParts (Node n@(_, (table, Just (Relation {relType=Child}))) forst) (w,s) = (w,sel:s)
      where
        sel = "("
           <> "SELECT array_to_json(array_agg(row_to_json("<>table<>"))) "
           <> "FROM (" <> subquery <> ") " <> table
           <> ") AS " <> table
           where subquery = requestToQuery schema (Node n forst)
    getQueryParts (Node n@(_, (table, Just (Relation {relType=Parent}))) forst) (w,s) = (wit:w,sel:s)
      where
        sel = "row_to_json(" <> table <> ".*) AS "<>table --TODO must be singular
        wit = table <> " AS ( " <> subquery <> " )"
          where subquery = requestToQuery schema (Node n forst)
    getQueryParts (Node n@(_, (table, Just (Relation {relType=Many}))) forst) (w,s) = (w,sel:s)
      where
        sel = "("
           <> "SELECT array_to_json(array_agg(row_to_json("<>table<>"))) "
           <> "FROM (" <> subquery <> ") " <> table
           <> ") AS " <> table
           where subquery = requestToQuery schema (Node n forst)
    --the following is just to remove the warning
    --getQueryParts is not total but requestToQuery is called only after addJoinConditions which ensures the only
    --posible relations are Child Parent Many
    getQueryParts (Node (_,(_,Nothing)) _) _ = undefined

requestToQuery schema (Node (Insert _ flds vals, (mainTbl, _)) _) =
  query
  where
    qi = QualifiedIdentifier schema mainTbl
    query = Data.Text.unwords [
      "INSERT INTO ", fromQi qi,
      " (" <> intercalate ", " (map (pgFmtIdent . fst) flds) <> ") ",
      "VALUES " <> intercalate ", "
        ( map (\v ->
            "(" <>
            intercalate ", " ( map insertableValue v ) <>
            ")"
          ) vals
        ),
      "RETURNING " <> fromQi qi <> ".*"
      ]

requestToQuery schema (Node (Update _ setWith conditions, (mainTbl, _)) _) =
  query
  where
    qi = QualifiedIdentifier schema mainTbl
    query = Data.Text.unwords [
      "UPDATE ", fromQi qi,
      " SET " <> intercalate ", " (map formatSet (M.toList setWith)) <> " ",
      ("WHERE " <> intercalate " AND " ( map (pgFmtCondition qi ) conditions )) `emptyOnNull` conditions,
      "RETURNING " <> fromQi qi <> ".*"
      ]
    formatSet ((c, jp), v) = pgFmtIdent c <> pgFmtJsonPath jp <> " = " <> insertableValue v

requestToQuery schema (Node (Delete _ conditions, (mainTbl, _)) _) =
  query
  where
    qi = QualifiedIdentifier schema mainTbl
    query = Data.Text.unwords [
      "DELETE FROM ", fromQi qi,
      ("WHERE " <> intercalate " AND " ( map (pgFmtCondition qi ) conditions )) `emptyOnNull` conditions,
      "RETURNING " <> fromQi qi <> ".*"
      ]
