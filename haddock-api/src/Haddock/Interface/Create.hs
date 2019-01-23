{-# LANGUAGE CPP, TupleSections, BangPatterns, LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wwarn #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Haddock.Interface.Create
-- Copyright   :  (c) Simon Marlow      2003-2006,
--                    David Waern       2006-2009,
--                    Mateusz Kowalczyk 2013
-- License     :  BSD-like
--
-- Maintainer  :  haddock@projects.haskell.org
-- Stability   :  experimental
-- Portability :  portable
--
-- This module provides a single function 'createInterface',
-- which creates a Haddock 'Interface' from the typechecking
-- results 'TypecheckedModule' from GHC.
-----------------------------------------------------------------------------
module Haddock.Interface.Create (createInterface) where

import Haddock.Types
import Haddock.Options
import Haddock.GhcUtils
import Haddock.Utils
import Haddock.Convert
import Haddock.Interface.LexParseRn

import qualified Data.Map as M
import Data.Map (Map)
import Data.List
import qualified Data.List.NonEmpty as NE
import Data.Maybe
import Control.Arrow ((&&&))
import Control.Monad
import Data.Traversable

import Avail hiding (avail)
import qualified Avail
import ConLike (ConLike(..))
import GHC
import GhcMonad
import HscTypes
import Name
import NameSet
import qualified Outputable
import Packages ( PackageName(..) )
import TcIface
import TcRnMonad
import FastString ( unpackFS )
import BasicTypes ( WarningSort(..), warningTxtContents
                  , TupleSort(..), Boxity(..), PromotionFlag(..) )
import qualified Outputable as O
import DynFlags ( getDynFlags )
import TysPrim    ( funTyConName )
import TysWiredIn ( listTyConName, nilDataConName, consDataConName, eqTyConName
                  , tupleDataCon, tupleTyConName)
import PrelNames  ( dATA_TUPLE, pRELUDE, gHC_PRIM, gHC_TYPES )

-- | Use a 'ModIface' to produce an 'Interface'.
-- To do this, we need access to already processed modules in the topological
-- sort. That's what's in the 'IfaceMap'.
createInterface :: ModIface
                -> [Flag]       -- Boolean flags
                -> IfaceMap     -- Locally processed modules
                -> InstIfaceMap -- External, already installed interfaces
                -> ErrMsgGhc Interface
createInterface mod_iface flags modMap instIfaceMap = do
  dflags <- getDynFlags

  let mdl            = mi_module mod_iface
      sem_mdl        = mi_semantic_module mod_iface
      is_sig         = isJust (mi_sig_of mod_iface)
      safety         = getSafeMode (mi_trust mod_iface)

      -- Not sure whether the relevant info is in these dflags
      (pkgNameFS, _) = modulePackageInfo dflags flags (Just mdl)
      pkgName        = fmap (unpackFS . (\(PackageName n) -> n)) pkgNameFS
      warnings       = mi_warns mod_iface

      -- See Note [Exporting built-in items]
      special_exports
        | mdl == gHC_TYPES  = listAvail <> eqAvail
        | mdl == gHC_PRIM   = funAvail
        | mdl == pRELUDE    = listAvail <> funAvail
        | mdl == dATA_TUPLE = tupsAvail
        | mdl == dATA_LIST  = listAvail
        | otherwise         = []
      !exportedNames = concatMap availNamesWithSelectors
                                 (special_exports <> mi_exports mod_iface)

      fixMap         = mkFixMap exportedNames (mi_fixities mod_iface)

  mod_iface_docs <- case mi_docs mod_iface of
    Just docs -> pure docs
    Nothing -> do
      liftErrMsg $ tell [O.showPpr dflags mdl ++ " has no docs in its .hi-file"]
      pure emptyDocs

  opts <- liftErrMsg $ mkDocOpts (docs_haddock_opts mod_iface_docs) flags mdl
  let prr | OptPrintRuntimeRep `elem` opts = ShowRuntimeRep
          | otherwise = HideRuntimeRep

  -- Process the top-level module header documentation.
  (!info, mbDoc) <- processModuleHeader pkgName safety
                                        (docs_language mod_iface_docs)
                                        (docs_extensions mod_iface_docs)
                                        (docs_mod_hdr mod_iface_docs)

  modWarn <- moduleWarning warnings

  let process = processDocStringParas pkgName
  docMap <- traverse process (docs_decls mod_iface_docs)
  argMap <- traverse (traverse process) (docs_args mod_iface_docs)

  warningMap <- mkWarningMap warnings exportedNames

  -- Are these all the (fam_)instances that we need?
  (instances, fam_instances) <- liftGhcToErrMsgGhc $ withSession $ \hsc_env -> liftIO $
    (md_insts &&& md_fam_insts)
       <$> initIfaceCheck (Outputable.text "createInterface'") hsc_env
                          (typecheckIface mod_iface)
  let localInsts = filter (nameIsLocalOrFrom sem_mdl)
                        $  map getName instances
                        ++ map getName fam_instances
      instanceMap = M.fromList (map (getSrcSpan &&& id) localInsts)

  let allWarnings = M.unions (warningMap : map ifaceWarningMap (M.elems modMap))

      -- Locations of all TH splices
      -- TODO: We use the splice info in 'Haddock.Backends.Xhtml.Layout.links' to
      -- determine what kind of link we want to generate. Since we depend on
      -- declaration locations there, it makes sense to get the splice locations
      -- together with the other locations from the extended .hie files.
      splices = []

  -- See Note [Exporting built-in items]
  let builtinTys = DsiSectionHeading 1 (HsDoc (mkHsDocString "Builtin syntax") [])
      bonus_ds mods
        | mdl == gHC_TYPES  = [ DsiExports (listAvail <> eqAvail) ] <> mods
        | mdl == gHC_PRIM   = [ builtinTys, DsiExports funAvail ] <> mods
        | mdl == pRELUDE    = let (hs, rest) = splitAt 2 mods
                              in hs <> [ DsiExports (listAvail <> funAvail) ] <> rest
        | mdl == dATA_TUPLE = mods <> [ DsiExports tupsAvail ]
        | mdl == dATA_LIST  = [ DsiExports listAvail ] <> mods
        | otherwise = mods

  -- The MAIN functionality: compute the export items which will
  -- each be the actual documentation of this module.
  exportItems <- mkExportItems prr modMap pkgName mdl allWarnings
                   docMap argMap fixMap splices
                   (docs_named_chunks mod_iface_docs)
                   (bonus_ds $ docs_structure mod_iface_docs) instIfaceMap

  let !visibleNames = mkVisibleNames instanceMap exportItems opts

  -- Measure haddock documentation coverage.
  let prunedExportItems0 = pruneExportItems exportItems
      !haddockable = 1 + length exportItems -- module + exports
      !haddocked = (if isJust mbDoc then 1 else 0) + length prunedExportItems0
      !coverage = (haddockable, haddocked)

  -- Prune the export list to just those declarations that have
  -- documentation, if the 'prune' option is on.
  let prunedExportItems'
        | OptPrune `elem` opts = prunedExportItems0
        | otherwise = exportItems
      !prunedExportItems = seqList prunedExportItems' `seq` prunedExportItems'

  return $! Interface {
    ifaceMod               = mdl
  , ifaceIsSig             = is_sig
  , ifaceInfo              = info
  , ifaceDoc               = Documentation mbDoc modWarn
  , ifaceRnDoc             = Documentation Nothing Nothing
  , ifaceOptions           = opts
  , ifaceDocMap            = docMap
  , ifaceArgMap            = argMap
  , ifaceRnDocMap          = M.empty
  , ifaceRnArgMap          = M.empty
  , ifaceExportItems       = prunedExportItems
  , ifaceRnExportItems     = []
  , ifaceExports           = exportedNames
  , ifaceVisibleExports    = visibleNames
  , ifaceFixMap            = fixMap
  , ifaceInstances         = instances
  , ifaceFamInstances      = fam_instances
  , ifaceOrphanInstances   = []
  , ifaceRnOrphanInstances = []
  , ifaceHaddockCoverage   = coverage
  , ifaceWarningMap        = warningMap
  , ifaceTokenizedSrc      = Nothing -- TODO: Get this from the extended .hie-files.
  }
  where
    -- Note [Exporting built-in items]
    --
    -- Some items do not show up in their modules exports simply because Haskell
    -- lacks the concrete syntax to represent such an export. We'd still like
    -- these to show up in docs, so we manually patch on some extra exports for a
    -- small number of modules:
    --
    --   * "GHC.Prim" should export @(->)@
    --   * "GHC.Types" should export @[]([], (:))@ and @(~)@
    --   * "Prelude" should export @(->)@ and @[]([], (:))@
    --   * "Data.Tuple" should export tuples up to arity 15 (that is the number
    --     that Haskell98 guarantees exist and that it also the point at which
    --     GHC stops providing instances)
    --
    listAvail = [ AvailTC listTyConName
                          [listTyConName, nilDataConName, consDataConName]
                          [] ]
    funAvail  = [ AvailTC funTyConName [funTyConName] [] ]
    eqAvail   = [ AvailTC eqTyConName [eqTyConName] [] ]
    tupsAvail = [ AvailTC tyName [tyName, datName] []
                | i<-[0..15]
                , let tyName = tupleTyConName BoxedTuple i
                , let datName = getName $ tupleDataCon Boxed i
                ]


-- | Given the information that comes out of a 'DsiModExport', decide which of
-- the re-exported modules can be linked directly and which modules need to have
-- their avails inlined. We can link directly to a module when:
--
--   * all of the stuff avail from that module is also available here
--   * that module is not marked as hidden
--
-- TODO: Do we need a special case for the current module?
unrestrictedModExports
  :: IfaceMap
  -> Avails
  -> [ModuleName]
  -> ErrMsgGhc ([Module], Avails)
     -- ^ ( modules exported without restriction
     --   , remaining exports not included in any
     --     of these modules
     --   )
unrestrictedModExports ifaceMap avails mod_names = do
    mods_and_exports <- fmap catMaybes $ for mod_names $ \mod_name -> do
      mdl <- liftGhcToErrMsgGhc $ findModule mod_name Nothing
      mb_modinfo <- liftGhcToErrMsgGhc $ getModuleInfo mdl
      case mb_modinfo of
        Nothing -> do
          dflags <- getDynFlags
          liftErrMsg $ tell [ "Bug: unrestrictedModExports: " ++ pretty dflags mdl]
          pure Nothing
        Just modinfo ->
          pure (Just (mdl, mkNameSet (modInfoExportsWithSelectors modinfo)))
    let unrestricted = filter everythingVisible mods_and_exports
        mod_exps = unionNameSets (map snd unrestricted)
        remaining = nubAvails (filterAvails (\n -> not (n `elemNameSet` mod_exps)) avails)
    pure (map fst unrestricted, remaining)
  where
    all_names = availsToNameSetWithSelectors avails

    -- Is everything in this (supposedly re-exported) module visible?
    everythingVisible :: (Module, NameSet) -> Bool
    everythingVisible (mdl, exps)
      | not (exps `isSubsetOf` all_names) = False
      | Just iface <- M.lookup mdl ifaceMap = OptHide `notElem` ifaceOptions iface
      | otherwise = True

    -- TODO: Add a utility based on IntMap.isSubmapOfBy
    isSubsetOf :: NameSet -> NameSet -> Bool
    isSubsetOf a b = nameSetAll (`elemNameSet` b) a


-------------------------------------------------------------------------------
-- Warnings
-------------------------------------------------------------------------------

-- TODO: Either find a different way of looking up the OccNames or change the Warnings or
-- WarningMap type.
mkWarningMap :: Warnings (HsDoc Name) -> [Name] -> ErrMsgGhc WarningMap
mkWarningMap warnings exps = case warnings of
  NoWarnings  -> pure M.empty
  WarnAll _   -> pure M.empty
  WarnSome ws ->
    -- Not sure if this is equivalent to the original code below.
    let expsOccEnv = mkOccEnv [(nameOccName n, n) | n <- exps]
        ws' = flip mapMaybe ws $ \(occ, w) ->
                (,w) <$> lookupOccEnv expsOccEnv occ
    {-
    let ws' = [ (n, w)
              | (occ, w) <- ws
              , elt <- lookupGlobalRdrEnv gre occ
              , let n = gre_name elt, n `elem` exps ]
    -}
    in M.fromList <$> traverse (traverse parseWarning) ws'

moduleWarning :: Warnings (HsDoc Name) -> ErrMsgGhc (Maybe (Doc Name))
moduleWarning = \case
  NoWarnings -> pure Nothing
  WarnSome _ -> pure Nothing
  WarnAll w  -> Just <$> parseWarning w

parseWarning :: WarningTxt (HsDoc Name) -> ErrMsgGhc (Doc Name)
parseWarning w =
  -- TODO: Find something more efficient than (foldl' appendHsDoc)
  format heading (foldl' appendHsDoc emptyHsDoc msgs)
  where
    format x msg = DocWarning . DocParagraph . DocAppend (DocString x)
                   <$> processDocString msg
    heading = case sort_ of
      WsWarning -> "Warning: "
      WsDeprecated -> "Deprecated: "
    (sort_, msgs) = warningTxtContents w


-------------------------------------------------------------------------------
-- Doc options
--
-- Haddock options that are embedded in the source file
-------------------------------------------------------------------------------


mkDocOpts :: Maybe String -> [Flag] -> Module -> ErrMsgM [DocOption]
mkDocOpts mbOpts flags mdl = do
  opts <- case mbOpts of
    Just opts -> case words $ replace ',' ' ' opts of
      [] -> tell ["No option supplied to DOC_OPTION/doc_option"] >> return []
      xs -> liftM catMaybes (mapM parseOption xs)
    Nothing -> return []
  pure (foldl go opts flags)
  where
    mdlStr = moduleString mdl

    -- Later flags override earlier ones
    go os m | m == Flag_HideModule mdlStr     = OptHide : os
            | m == Flag_ShowModule mdlStr     = filter (/= OptHide) os
            | m == Flag_ShowAllModules        = filter (/= OptHide) os
            | m == Flag_ShowExtensions mdlStr = OptShowExtensions : os
            | otherwise                       = os

parseOption :: String -> ErrMsgM (Maybe DocOption)
parseOption "hide"            = return (Just OptHide)
parseOption "prune"           = return (Just OptPrune)
parseOption "not-home"        = return (Just OptNotHome)
parseOption "show-extensions" = return (Just OptShowExtensions)
parseOption "print-explicit-runtime-reps" = return (Just OptPrintRuntimeRep)
parseOption other = tell ["Unrecognised option: " ++ other] >> return Nothing

-- | Extract a map of fixity declarations only
mkFixMap :: [Name] -> [(OccName, Fixity)] -> FixMap
mkFixMap exps occFixs =
    M.fromList $ flip mapMaybe occFixs $ \(occ, fix_) ->
      (,fix_) <$> lookupOccEnv expsOccEnv occ
  where
    expsOccEnv = mkOccEnv (map (nameOccName &&& id) exps)

mkExportItems
  :: PrintRuntimeReps
  -> IfaceMap
  -> Maybe Package      -- this package
  -> Module             -- this module
  -> WarningMap
  -> DocMap Name        -- docs (keyed by 'Name's)
  -> ArgMap Name        -- docs for arguments (keyed by 'Name's) 
  -> FixMap
  -> [SrcSpan]          -- splice locations
  -> Map String (HsDoc Name) -- named chunks
  -> DocStructure
  -> InstIfaceMap
  -> ErrMsgGhc [ExportItem GhcRn]
mkExportItems
  prr modMap mbPkgName thisMod warnings
  docMap argMap fixMap splices namedChunks dsItems instIfaceMap =
    concat <$> traverse lookupExport dsItems
  where
    lookupExport :: DocStructureItem -> ErrMsgGhc [ExportItem GhcRn]
    lookupExport = \case
      DsiSectionHeading lev hsDoc -> do
        doc <- processDocString hsDoc
        pure [ExportGroup lev "" doc]
      DsiDocChunk hsDoc -> do
        doc <- processDocStringParas mbPkgName hsDoc
        pure [ExportDoc doc]
      DsiNamedChunkRef ref -> do
        case M.lookup ref namedChunks of
          Nothing -> do
            liftErrMsg $ tell ["Cannot find documentation for: $" ++ ref]
            pure []
          Just hsDoc -> do
            doc <- processDocStringParas mbPkgName hsDoc
            pure [ExportDoc doc]
      DsiExports avails ->
        -- TODO: We probably don't need nubAvails here.
        -- mkDocStructureFromExportList already uses it.
        concat <$> traverse availExport (nubAvails avails)
      DsiModExport mod_names avails -> do
        -- only consider exporting a module if we are sure we are really
        -- exporting the whole module and not some subset.
        (unrestricted_mods, remaining_avails) <- unrestrictedModExports modMap avails (NE.toList mod_names)
        avail_exps <- concat <$> traverse availExport remaining_avails
        pure (map ExportModule unrestricted_mods ++ avail_exps)

    availExport avail =
      availExportItem prr modMap thisMod warnings
        docMap argMap fixMap splices instIfaceMap avail

availExportItem :: PrintRuntimeReps
                -> IfaceMap
                -> Module             -- this module
                -> WarningMap
                -> DocMap Name        -- docs (keyed by 'Name's)
                -> ArgMap Name        -- docs for arguments (keyed by 'Name's) 
                -> FixMap
                -> [SrcSpan]          -- splice locations
                -> InstIfaceMap
                -> AvailInfo
                -> ErrMsgGhc [ExportItem GhcRn]
availExportItem prr modMap thisMod warnings
  docMap argMap fixMap _splices instIfaceMap
  availInfo = declWith availInfo
  where
    declWith :: AvailInfo -> ErrMsgGhc [ ExportItem GhcRn ]
    declWith avail = do
      dflags <- getDynFlags
      let t = availName avail -- NB: 't' might not be in the scope of 'avail'.
                              -- Example: @data C = D@, where C isn't exported.
      mayDecl <- hiDecl prr t
      case mayDecl of
        Nothing -> return [ ExportNoDecl t [] ]
        Just decl -> do
          docs_ <- do
            let tmod = nameModule t
            if tmod == thisMod
              then pure (lookupDocs avail warnings docMap argMap)
              else case M.lookup tmod modMap of
                Just iface ->
                  pure (lookupDocs avail warnings (ifaceDocMap iface) (ifaceArgMap iface))
                Nothing ->
                  -- We try to get the subs and docs
                  -- from the installed .haddock file for that package.
                  -- TODO: This needs to be more sophisticated to deal
                  -- with signature inheritance
                  case M.lookup (nameModule t) instIfaceMap of
                    Nothing -> do
                       liftErrMsg $ tell
                          ["Warning: " ++ pretty dflags thisMod ++
                           ": Couldn't find .haddock for export " ++ pretty dflags t]
                       let subs_ = availNoDocs avail
                       pure (noDocForDecl, subs_)
                    Just instIface ->
                      pure (lookupDocs avail warnings (instDocMap instIface) (instArgMap instIface))
          availExportDecl avail decl docs_

    availExportDecl :: AvailInfo -> LHsDecl GhcRn
                    -> (DocForDecl Name, [(Name, DocForDecl Name)])
                    -> ErrMsgGhc [ ExportItem GhcRn ]
    availExportDecl avail decl (doc, subs)
      | availExportsDecl avail = do
          -- bundled pattern synonyms only make sense if the declaration is
          -- exported (otherwise there would be nothing to bundle to)
          bundledPatSyns <- findBundledPatterns avail

          let
            patSynNames =
              concatMap (getMainDeclBinder . fst) bundledPatSyns

            fixities =
                [ (n, f)
                | n <- availName avail : fmap fst subs ++ patSynNames
                , Just f <- [M.lookup n fixMap]
                ]

          extracted <- extractDecl prr (availName avail) decl

          return [ ExportDecl {
                       expItemDecl      = restrictTo (fmap fst subs) extracted
                     , expItemPats      = bundledPatSyns
                     , expItemMbDoc     = doc
                     , expItemSubDocs   = subs
                     , expItemInstances = []
                     , expItemFixities  = fixities
                     , expItemSpliced   = False
                     }
                 ]

      | otherwise =
          let extractSub (sub, sub_doc) = do
                extracted <- extractDecl prr sub decl
                pure (ExportDecl {
                          expItemDecl      = extracted
                        , expItemPats      = []
                        , expItemMbDoc     = sub_doc
                        , expItemSubDocs   = []
                        , expItemInstances = []
                        , expItemFixities  = [ (sub, f) | Just f <- [M.lookup sub fixMap] ]
                        , expItemSpliced   = False
                        })
          in traverse extractSub subs

    findBundledPatterns :: AvailInfo -> ErrMsgGhc [(HsDecl GhcRn, DocForDecl Name)]
    findBundledPatterns avail = do
      patsyns <- for constructor_names $ \name -> do
        mtyThing <- liftGhcToErrMsgGhc (lookupName name)
        case mtyThing of
          Just (AConLike PatSynCon{}) -> do
            export_items <- declWith (Avail.avail name)
            pure [ (unLoc patsyn_decl, patsyn_doc)
                 | ExportDecl {
                       expItemDecl  = patsyn_decl
                     , expItemMbDoc = patsyn_doc
                     } <- export_items
                 ]
          _ -> pure []
      pure (concat patsyns)
      where
        constructor_names =
          filter isDataConName (availSubordinates avail)

-- this heavily depends on the invariants stated in Avail
availExportsDecl :: AvailInfo -> Bool
availExportsDecl (AvailTC ty_name names _)
  | n : _ <- names = ty_name == n
  | otherwise      = False
availExportsDecl _ = True

availSubordinates :: AvailInfo -> [Name]
availSubordinates avail =
  filter (/= availName avail) (availNamesWithSelectors avail)

availNoDocs :: AvailInfo -> [(Name, DocForDecl Name)]
availNoDocs avail =
  zip (availSubordinates avail) (repeat noDocForDecl)

hiDecl :: PrintRuntimeReps -> Name -> ErrMsgGhc (Maybe (LHsDecl GhcRn))
hiDecl prr t = do
  dflags <- getDynFlags
  mayTyThing <- liftGhcToErrMsgGhc $ lookupName t
  let bugWarn = O.showSDoc dflags . warnLine
  case mayTyThing of
    Nothing -> do
      liftErrMsg $ tell ["Warning: Not found in environment: " ++ pretty dflags t]
      return Nothing
    Just x -> case tyThingToLHsDecl prr x of
      Left m -> liftErrMsg (tell [bugWarn m]) >> return Nothing
      Right (m, t') -> liftErrMsg (tell $ map bugWarn m)
                      >> return (Just $ noLoc t')
    where
      warnLine x = O.text "haddock-bug:" O.<+> O.text x O.<>
                   O.comma O.<+> O.quotes (O.ppr t) O.<+>
                   O.text "-- Please report this on Haddock issue tracker!"

-- | Lookup docs for a declaration from maps.
lookupDocs :: AvailInfo -> WarningMap -> DocMap Name -> ArgMap Name
           -> (DocForDecl Name, [(Name, DocForDecl Name)])
lookupDocs avail warnings docMap argMap =
  ( lookupDocForDecl (availName avail)
  , [ (s, lookupDocForDecl s) | s <- availSubordinates avail ]
  )
  where
    lookupDoc x = Documentation (M.lookup x docMap) (M.lookup x warnings)
    lookupArgDoc x = M.findWithDefault M.empty x argMap
    lookupDocForDecl x = (lookupDoc x, lookupArgDoc x)


-- | Sometimes the declaration we want to export is not the "main" declaration:
-- it might be an individual record selector or a class method.  In these
-- cases we have to extract the required declaration (and somehow cobble
-- together a type signature for it...).
extractDecl
  :: PrintRuntimeReps           -- ^ should we print 'RuntimeRep' tyvars?
  -> Name                       -- ^ name of subdecl to extract
  -> LHsDecl GhcRn              -- ^ parent decl
  -> ErrMsgGhc (LHsDecl GhcRn)  -- ^ extracted subdecl
extractDecl prr name decl
  | name `elem` getMainDeclBinder (unLoc decl) = pure decl
  | otherwise  =
    case unLoc decl of
      TyClD _ d@ClassDecl {} ->
        let
          matchesMethod =
            [ lsig
            | lsig <- tcdSigs d
            , ClassOpSig _ False _ _ <- pure $ unLoc lsig
              -- Note: exclude `default` declarations (see #505)
            , name `elem` sigName lsig
            ]

          matchesAssociatedType =
            [ lfam_decl
            | lfam_decl <- tcdATs d
            , name == unLoc (fdLName (unLoc lfam_decl))
            ]

            -- TODO: document fixity
        in case (matchesMethod, matchesAssociatedType)  of
          ([s0], _) -> let (n, tyvar_names) = (tcdName d, tyClDeclTyVars d)
                           L pos sig = addClassContext n tyvar_names s0
                       in pure (L pos (SigD noExt sig))
          (_, [L pos fam_decl]) -> pure (L pos (TyClD noExt (FamDecl noExt fam_decl)))

          ([], []) -> do
            famInstDeclOpt <- hiDecl prr name
            case famInstDeclOpt of
              Nothing -> O.pprPanic "extractDecl" (O.text "Failed to find decl for" O.<+> O.ppr name)
              Just famInstDecl -> extractDecl prr name famInstDecl
          _ -> O.pprPanic "extractDecl" (O.text "Ambiguous decl for" O.<+> O.ppr name O.<+> O.text "in class:"
                                         O.$$ O.nest 4 (O.ppr d)
                                         O.$$ O.text "Matches:"
                                         O.$$ O.nest 4 (O.ppr matchesMethod O.<+> O.ppr matchesAssociatedType))
      TyClD _ d@DataDecl {} -> pure $
        let (n, tyvar_tys) = (tcdName d, lHsQTyVarsToTypes (tyClDeclTyVars d))
        in if isDataConName name
           then SigD noExt <$> extractPatternSyn name n (map HsValArg tyvar_tys) (dd_cons (tcdDataDefn d))
           else SigD noExt <$> extractRecSel name n (map HsValArg tyvar_tys) (dd_cons (tcdDataDefn d))
      TyClD _ FamDecl {}
        | isValName name
        -> do
          famInstOpt <- hiDecl prr name
          case famInstOpt of
            Nothing -> O.pprPanic "extractDecl" (O.text "Failed to find decl for" O.<+> O.ppr name)
            Just famInst -> extractDecl prr name famInst
      InstD _ (DataFamInstD _ (DataFamInstDecl (HsIB { hsib_body =
                             FamEqn { feqn_tycon = L _ n
                                    , feqn_pats  = tys
                                    , feqn_rhs   = defn }}))) -> pure $
        if isDataConName name
        then SigD noExt <$> extractPatternSyn name n tys (dd_cons defn)
        else SigD noExt <$> extractRecSel name n tys (dd_cons defn)
      InstD _ (ClsInstD _ ClsInstDecl { cid_datafam_insts = insts })
        | isDataConName name ->
            let matches = [ d' | L _ d'@(DataFamInstDecl (HsIB { hsib_body =
                                          FamEqn { feqn_rhs   = dd
                                                 }
                                         })) <- insts
                               , name `elem` map unLoc (concatMap (getConNames . unLoc) (dd_cons dd))
                               ]
            in case matches of
                [d0] -> extractDecl prr name (noLoc (InstD noExt (DataFamInstD noExt d0)))
                _    -> error "internal: extractDecl (ClsInstD)"
        | otherwise ->
            let matches = [ d' | L _ d'@(DataFamInstDecl (HsIB { hsib_body = d }))
                                   <- insts
                                 -- , L _ ConDecl { con_details = RecCon rec } <- dd_cons (feqn_rhs d)
                               , RecCon rec <- map (getConArgs . unLoc) (dd_cons (feqn_rhs d))
                               , ConDeclField { cd_fld_names = ns } <- map unLoc (unLoc rec)
                               , L _ n <- ns
                               , extFieldOcc n == name
                          ]
            in case matches of
              [d0] -> extractDecl prr name (noLoc . InstD noExt $ DataFamInstD noExt d0)
              _ -> error "internal: extractDecl (ClsInstD)"
      _ -> O.pprPanic "extractDecl" $
        O.text "Unhandled decl for" O.<+> O.ppr name O.<> O.text ":"
        O.$$ O.nest 4 (O.ppr decl)

extractPatternSyn :: Name -> Name -> [LHsTypeArg GhcRn] -> [LConDecl GhcRn] -> LSig GhcRn
extractPatternSyn nm t tvs cons =
  case filter matches cons of
    [] -> error "extractPatternSyn: constructor pattern not found"
    con:_ -> extract <$> con
 where
  matches :: LConDecl GhcRn -> Bool
  matches (L _ con) = nm `elem` (unLoc <$> getConNames con)
  extract :: ConDecl GhcRn -> Sig GhcRn
  extract con =
    let args =
          case getConArgs con of
            PrefixCon args' -> args'
            RecCon (L _ fields) -> cd_fld_type . unLoc <$> fields
            InfixCon arg1 arg2 -> [arg1, arg2]
        typ = longArrow args (data_ty con)
        typ' =
          case con of
            ConDeclH98 { con_mb_cxt = Just cxt } -> noLoc (HsQualTy noExt cxt typ)
            _ -> typ
        typ'' = noLoc (HsQualTy noExt (noLoc []) typ')
    in PatSynSig noExt [noLoc nm] (mkEmptyImplicitBndrs typ'')

  longArrow :: [LHsType GhcRn] -> LHsType GhcRn -> LHsType GhcRn
  longArrow inputs output = foldr (\x y -> noLoc (HsFunTy noExt x y)) output inputs

  data_ty con
    | ConDeclGADT{} <- con = con_res_ty con
    | otherwise = foldl' (\x y -> noLoc (mkAppTyArg x y)) (noLoc (HsTyVar noExt NotPromoted (noLoc t))) tvs
                    where mkAppTyArg :: LHsType GhcRn -> LHsTypeArg GhcRn -> HsType GhcRn
                          mkAppTyArg f (HsValArg ty) = HsAppTy noExt f ty
                          mkAppTyArg f (HsTypeArg ki) = HsAppKindTy noExt f ki
                          mkAppTyArg f (HsArgPar _) = HsParTy noExt f

extractRecSel :: Name -> Name -> [LHsTypeArg GhcRn] -> [LConDecl GhcRn]
              -> LSig GhcRn
extractRecSel _ _ _ [] = error "extractRecSel: selector not found"

extractRecSel nm t tvs (L _ con : rest) =
  case getConArgs con of
    RecCon (L _ fields) | ((l,L _ (ConDeclField _ _nn ty _)) : _) <- matching_fields fields ->
      L l (TypeSig noExt [noLoc nm] (mkEmptySigWcType (noLoc (HsFunTy noExt data_ty (getBangType ty)))))
    _ -> extractRecSel nm t tvs rest
 where
  matching_fields :: [LConDeclField GhcRn] -> [(SrcSpan, LConDeclField GhcRn)]
  matching_fields flds = [ (l,f) | f@(L _ (ConDeclField _ ns _ _)) <- flds
                                 , L l n <- ns, extFieldOcc n == nm ]
  data_ty
    -- ResTyGADT _ ty <- con_res con = ty
    | ConDeclGADT{} <- con = con_res_ty con
    | otherwise = foldl' (\x y -> noLoc (mkAppTyArg x y)) (noLoc (HsTyVar noExt NotPromoted (noLoc t))) tvs
                   where mkAppTyArg :: LHsType GhcRn -> LHsTypeArg GhcRn -> HsType GhcRn
                         mkAppTyArg f (HsValArg ty) = HsAppTy noExt f ty
                         mkAppTyArg f (HsTypeArg ki) = HsAppKindTy noExt f ki
                         mkAppTyArg f (HsArgPar _) = HsParTy noExt f 

-- | Keep export items with docs.
pruneExportItems :: [ExportItem GhcRn] -> [ExportItem GhcRn]
pruneExportItems = filter hasDoc
  where
    hasDoc (ExportDecl{expItemMbDoc = (Documentation d _, _)}) = isJust d
    hasDoc _ = True


mkVisibleNames :: InstMap -> [ExportItem GhcRn] -> [DocOption] -> [Name]
mkVisibleNames instMap exports opts
  | OptHide `elem` opts = []
  | otherwise = let ns = concatMap exportName exports
                in seqList ns `seq` ns
  where
    exportName e@ExportDecl {} = name ++ subs ++ patsyns
      where subs    = map fst (expItemSubDocs e)
            patsyns = concatMap (getMainDeclBinder . fst) (expItemPats e)
            name = case unLoc $ expItemDecl e of
              InstD _ d -> maybeToList $ M.lookup (getInstLoc d) instMap
              decl      -> getMainDeclBinder decl
    exportName ExportNoDecl {} = [] -- we don't count these as visible, since
                                    -- we don't want links to go to them.
    exportName _ = []

seqList :: [a] -> ()
seqList [] = ()
seqList (x : xs) = x `seq` seqList xs
