{-# LANGUAGE RankNTypes #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Haddock.Backends.Annot
-- Copyright   :  (c) Ranjit Jhala
-- License     :  BSD-like
--
-- Maintainer  :  haddock@projects.haskell.org
-- Stability   :  experimental
-- Portability :  portable
--
-- Write out HsColour compatible type annotations
-----------------------------------------------------------------------------

module Haddock.Backends.Annot (
    ppAnnot
  ) where

import DynFlags         (unsafeGlobalDynFlags)
import FastString
import GHC
import GHC.Exts         (groupWith)
import Id               (idName, isDictId)
import IfaceSyn         (AltPpr (..), ShowSub (..), ShowHowMuch (..))
import IfaceType        (ShowForAllFlag (..))
import NameSet          (NameSet)
import Outputable
import PprTyThing
import Var              (Var (..), isId)

import Data.Data
import Data.Maybe       (catMaybes)
import Haddock.Syb
import Haddock.Types
import System.FilePath
import System.IO
import qualified Data.List as L
import qualified Data.Map as M

ppAnnot :: [Interface] -> FilePath -> FilePath -> IO ()
ppAnnot ifaces odir file
  = do putStrLn $ "Writing Annots to: " ++ target
       withFile target WriteMode $ \h -> mapM_ (render h) ifaces
    where target = odir </> file

render :: Handle -> Interface -> IO ()
render annH iface
  = do putStrLn $ "Render Annot: src = " ++ src ++ " module = " ++ modl
       hPutStr annH annots
    where src     = ifaceOrigFilename iface
          modl    = moduleNameString $ moduleName $ ifaceMod iface
          annots  = show_AnnMap modl $ getAnnMap (fsLit src) $ ifaceTcSource iface

newtype AnnMap = Ann (M.Map Loc (String, String))
type Loc = SrcSpan

show_AnnMap :: String -> AnnMap -> String
show_AnnMap modl annMap  = "\n\n" ++ (concatMap ppAnn $ realAnns annMap)
    where realAnns (Ann m) = dropBadSpans (M.toList m)

          -- Discard UnhelpfulSpans
          dropBadSpans [] = []
          dropBadSpans ((RealSrcSpan ss, v):xs) = (ss, v) : dropBadSpans xs
          dropBadSpans ((UnhelpfulSpan _msg, _v):xs) = dropBadSpans xs

          ppAnn :: (RealSrcSpan, ([Char], [Char])) -> [Char]
          ppAnn (l, (x,s)) =  x ++ "\n"
                           ++ modl ++ "\n"
                           ++ show (srcSpanStartLine l) ++ "\n"
                           ++ show (srcSpanStartCol l)  ++ "\n"
                           ++ show (length $ lines s)   ++ "\n"
                           ++ s ++ "\n\n\n"

---------------------------------------------------------------------------
-- Extract Annotations ----------------------------------------------------
---------------------------------------------------------------------------

getAnnMap ::  Data a => FastString -> a -> AnnMap
getAnnMap src tcm  = Ann $ M.fromList $ canonize $ anns
  where anns   = [(l, (s, renderId x)) | (l, (s, x)) <- rs ++ ws ]
        rs     = [(l, (s, x)) | (_,l,s) <- getLocEs tcm, x <- typs s]
        ws     = [(l, (s, x)) | (s, (x, Just l)) <- ns]
        ns     = getNames src tcm
        tm     = M.fromList ns
        typs s = case s `M.lookup` tm of
                   Nothing    -> []
                   Just (x,_) -> [x]

canonize :: (Ord b, Eq a) => [(b, (t, [a]))] -> [(b, (t, [a]))]
canonize anns = maximumBy cmp $ groupWith fst anns
  where maximumBy o = catMaybes . fmap (safeHead . L.sortBy o)
        safeHead [] = Nothing
        safeHead (x:_) = Just x
        cmp (_,(_,x1)) (_,(_,x2))
          | x1 == x2              = EQ
          | length x1 < length x2 = GT
          | otherwise             = LT

getLocEs ::  (Data a) => a -> [(HsExpr Id, Loc, String)]
getLocEs z = [(e, l, stripParens $ unsafePpr e) | L l e <- findLEs z]
  where stripParens ('(':s)  = stripParens s
        stripParens s        = stripRParens (reverse s)
        stripRParens (')':s) = stripRParens s
        stripRParens s       = reverse s

getNames ::  (Data a) => FastString -> a -> [(String, (Id, Maybe Loc))]
getNames src z = [(unsafePpr x, (x, idLoc src x)) | x <- findIds z]

renderId :: Id -> String
renderId = showSDocForUser unsafeGlobalDynFlags neverQualify . pprTyThing showSub . AnId

showSub :: ShowSub
showSub = ShowSub {
    ss_how_much = ShowHeader (AltPpr Nothing)
  , ss_forall = ShowForAllWhen
  }

idLoc :: FastString -> Id -> Maybe Loc
idLoc src x
  | not (isGoodSrcSpan sp)
  = Nothing
  | Just src /= fmap srcSpanFile (realSrcSpan sp)
  = Nothing
  | otherwise              = Just sp
  where sp  = nameSrcSpan $ idName x

realSrcSpan :: SrcSpan -> Maybe RealSrcSpan
realSrcSpan ss =
  case ss of
    RealSrcSpan rs -> Just rs
    UnhelpfulSpan _msg -> Nothing

unsafePpr :: Outputable a => a -> String
unsafePpr =
  showSDocUnsafe . ppr

---------------------------------------------------------------------------
-- Visiting and Extracting Identifiers ------------------------------------
-- From Tamar Christina: http://mistuke.wordpress.com/category/vsx --------
---------------------------------------------------------------------------

type GenericQ r = forall a. Data a => a -> r

-- | Summarise all nodes in top-down, left-to-right order
everythingButQ :: (r -> r -> r) -> [TypeRep] -> GenericQ r -> GenericQ r
everythingButQ k q f x
  = foldl k (f x) fsp
    where fsp = case isPost x q of
                  True  -> []
                  False -> gmapQ (everythingButQ k q f) x

isPost :: Typeable a => a -> [TypeRep] -> Bool
isPost a = or . map (== typeOf a)

-- | Get a list of all entities that meet a predicate
listifyBut :: Typeable r => (r -> Bool) -> [TypeRep] -> GenericQ [r]
listifyBut p q
  = everythingButQ (++) q ([] `mkQ` (\x -> if p x then [x] else []))

-- | Types to avoid inspecting. We should not enter any PostTcKind
-- nor NameSet because these are blank after type checking.
skipGuards :: [TypeRep]
skipGuards = [ typeRep (Proxy :: Proxy NameSet)
             , typeRep (Proxy :: Proxy (PostTc Id Kind))]

findIds :: Data a => a -> [Id]
findIds a = listifyBut idPredicate skipGuards a

idPredicate :: Var -> Bool
idPredicate v =
  isId v && and [
      not (isDictId v)
    , not (isGeneratedId v)
    ]

-- | Filter out compiler-generated names like @$trModule@ or @$cmappend@.
isGeneratedId :: Var -> Bool
isGeneratedId v =
  case unsafePpr v of
    ('$':_:_) -> True -- $a but not $
    _ -> False

findLEs :: Data a => a -> [LHsExpr Id]
findLEs a = listifyBut (isGoodSrcSpan . getLoc) skipGuards a
