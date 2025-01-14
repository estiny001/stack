{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Module exporting a function to create a pruned dependency graph given a
-- 'DotOpts' value.
module Stack.DependencyGraph
  ( createPrunedDependencyGraph
  , resolveDependencies
  , pruneGraph
  ) where

import qualified Data.Foldable as F
import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.Traversable as T
import           Distribution.License ( License (..) )
import qualified Distribution.PackageDescription as PD
import           Distribution.Types.PackageName ( mkPackageName )
import           Path ( parent )
import           RIO.Process ( HasProcessContext (..) )
import           Stack.Build ( loadPackage )
import           Stack.Build.Installed ( getInstalled, toInstallMap )
import           Stack.Build.Source
                   ( loadCommonPackage, loadLocalPackage, loadSourceMap )
import           Stack.Build.Target( NeedTargets (..), parseTargets )
import           Stack.Package ( Package (..), setOfPackageDeps )
import           Stack.Prelude hiding ( Display (..), pkgName, loadPackage )
import qualified Stack.Prelude ( pkgName )
import           Stack.Runners
                   ( ShouldReexec (..), withBuildConfig, withConfig
                   , withEnvConfig
                   )
import           Stack.SourceMap
                   ( globalsFromHints, mkProjectPackage, pruneGlobals )
import           Stack.Types.BuildConfig
                   ( BuildConfig (..), HasBuildConfig (..) )
import           Stack.Types.BuildOpts
                   ( BuildOptsCLI (..), buildOptsMonoidBenchmarksL
                   , buildOptsMonoidTestsL, defaultBuildOptsCLI
                   )
import           Stack.Types.Compiler ( wantedToActual )
import           Stack.Types.Config ( HasConfig (..) )
import           Stack.Types.DependencyTree ( DotPayload (..) )
import           Stack.Types.DotOpts ( DotOpts (..) )
import           Stack.Types.DumpPackage ( DumpPackage (..) )
import           Stack.Types.EnvConfig ( EnvConfig (..), HasSourceMap (..) )
import           Stack.Types.GHCVariant ( HasGHCVariant (..) )
import           Stack.Types.GhcPkgId
                   ( GhcPkgId, ghcPkgIdString, parseGhcPkgId )
import           Stack.Types.GlobalOpts ( globalOptsBuildOptsMonoidL )
import           Stack.Types.Package ( LocalPackage (..) )
import           Stack.Types.Platform ( HasPlatform (..) )
import           Stack.Types.Runner ( HasRunner (..), Runner, globalOptsL )
import           Stack.Types.SourceMap
                   ( CommonPackage (..), DepPackage (..), ProjectPackage (..)
                   , SMActual (..), SMWanted (..), SourceMap (..)
                   )

-- | Type representing exceptions thrown by functions exported by the
-- "Stack.DependencyGraph" module.
data DependencyGraphException
  = DependencyNotFoundBug GhcPkgId
  | PackageNotFoundBug PackageName
  deriving (Show, Typeable)

instance Exception DependencyGraphException where
  displayException (DependencyNotFoundBug depId) = bugReport "[S-7071]" $ concat
    [ "Expected to find "
    , ghcPkgIdString depId
    , " in global DB."
    ]
  displayException (PackageNotFoundBug pkgName) = bugReport "[S-7151]" $ concat
    [ "The '"
    , packageNameString pkgName
    , "' package was not found in any of the dependency sources."
    ]

-- | Create the dependency graph and also prune it as specified in the dot
-- options. Returns a set of local names and a map from package names to
-- dependencies.
createPrunedDependencyGraph ::
     DotOpts
  -> RIO
       Runner
       (Set PackageName, Map PackageName (Set PackageName, DotPayload))
createPrunedDependencyGraph dotOpts = withDotConfig dotOpts $ do
  localNames <- view $ buildConfigL.to (Map.keysSet . smwProject . bcSMWanted)
  logDebug "Creating dependency graph"
  resultGraph <- createDependencyGraph dotOpts
  let pkgsToPrune = if dotIncludeBase dotOpts
                      then dotPrune dotOpts
                      else Set.insert "base" (dotPrune dotOpts)
      prunedGraph = pruneGraph localNames pkgsToPrune resultGraph
  logDebug "Returning pruned dependency graph"
  pure (localNames, prunedGraph)

-- Plumbing for --test and --bench flags
withDotConfig ::
     DotOpts
  -> RIO DotConfig a
  -> RIO Runner a
withDotConfig opts inner =
  local (over globalOptsL modifyGO) $
    if dotGlobalHints opts
      then withConfig NoReexec $ withBuildConfig withGlobalHints
      else withConfig YesReexec withReal
 where
  withGlobalHints = do
    bconfig <- view buildConfigL
    globals <- globalsFromHints $ smwCompiler $ bcSMWanted bconfig
    fakeGhcPkgId <- parseGhcPkgId "ignored"
    actual <- either throwIO pure $
              wantedToActual $ smwCompiler $
              bcSMWanted bconfig
    let smActual = SMActual
          { smaCompiler = actual
          , smaProject = smwProject $ bcSMWanted bconfig
          , smaDeps = smwDeps $ bcSMWanted bconfig
          , smaGlobal = Map.mapWithKey toDump globals
          }
        toDump :: PackageName -> Version -> DumpPackage
        toDump name version = DumpPackage
          { dpGhcPkgId = fakeGhcPkgId
          , dpPackageIdent = PackageIdentifier name version
          , dpSublib = Nothing
          , dpLicense = Nothing
          , dpLibDirs = []
          , dpLibraries = []
          , dpHasExposedModules = True
          , dpExposedModules = mempty
          , dpDepends = []
          , dpHaddockInterfaces = []
          , dpHaddockHtml = Nothing
          , dpIsExposed = True
          }
        actualPkgs = Map.keysSet (smaDeps smActual) <>
                     Map.keysSet (smaProject smActual)
        prunedActual = smActual { smaGlobal = pruneGlobals (smaGlobal smActual) actualPkgs }
    targets <- parseTargets NeedTargets False boptsCLI prunedActual
    logDebug "Loading source map"
    sourceMap <- loadSourceMap targets boptsCLI smActual
    let dc = DotConfig
                { dcBuildConfig = bconfig
                , dcSourceMap = sourceMap
                , dcGlobalDump = toList $ smaGlobal smActual
                }
    logDebug "DotConfig fully loaded"
    runRIO dc inner

  withReal = withEnvConfig NeedTargets boptsCLI $ do
    envConfig <- ask
    let sourceMap = envConfigSourceMap envConfig
    installMap <- toInstallMap sourceMap
    (_, globalDump, _, _) <- getInstalled installMap
    let dc = DotConfig
          { dcBuildConfig = envConfigBuildConfig envConfig
          , dcSourceMap = sourceMap
          , dcGlobalDump = globalDump
          }
    runRIO dc inner

  boptsCLI = defaultBuildOptsCLI
    { boptsCLITargets = dotTargets opts
    , boptsCLIFlags = dotFlags opts
    }
  modifyGO =
    (if dotTestTargets opts
       then set (globalOptsBuildOptsMonoidL.buildOptsMonoidTestsL) (Just True)
       else id) .
    (if dotBenchTargets opts
       then set (globalOptsBuildOptsMonoidL.buildOptsMonoidBenchmarksL) (Just True)
       else id)

-- | Create the dependency graph, the result is a map from a package
-- name to a tuple of dependencies and payload if available. This
-- function mainly gathers the required arguments for
-- @resolveDependencies@.
createDependencyGraph ::
     DotOpts
  -> RIO DotConfig (Map PackageName (Set PackageName, DotPayload))
createDependencyGraph dotOpts = do
  sourceMap <- view sourceMapL
  locals <- for (toList $ smProject sourceMap) loadLocalPackage
  let graph = Map.fromList $ projectPackageDependencies dotOpts (filter lpWanted locals)
  globalDump <- view $ to dcGlobalDump
  -- TODO: Can there be multiple entries for wired-in-packages? If so,
  -- this will choose one arbitrarily..
  let globalDumpMap = Map.fromList $ map (\dp -> (Stack.Prelude.pkgName (dpPackageIdent dp), dp)) globalDump
      globalIdMap = Map.fromList $ map (dpGhcPkgId &&& dpPackageIdent) globalDump
  let depLoader = createDepLoader sourceMap globalDumpMap globalIdMap loadPackageDeps
      loadPackageDeps name version loc flags ghcOptions cabalConfigOpts
        -- Skip packages that can't be loaded - see
        -- https://github.com/commercialhaskell/stack/issues/2967
        | name `elem` [mkPackageName "rts", mkPackageName "ghc"] =
            pure ( Set.empty
                 , DotPayload (Just version) (Just $ Right BSD3) Nothing )
        | otherwise =
            fmap (setOfPackageDeps &&& makePayload loc)
                 (loadPackage loc flags ghcOptions cabalConfigOpts)
  resolveDependencies (dotDependencyDepth dotOpts) graph depLoader
 where
  makePayload loc pkg = DotPayload (Just $ packageVersion pkg)
                                   (Just $ packageLicense pkg)
                                   (Just $ PLImmutable loc)

-- | Resolve the direct (depth 0) external dependencies of the given local
-- packages (assumed to come from project packages)
projectPackageDependencies ::
     DotOpts
  -> [LocalPackage]
  -> [(PackageName, (Set PackageName, DotPayload))]
projectPackageDependencies dotOpts locals =
  map (\lp -> let pkg = localPackageToPackage lp
                  pkgDir = parent $ lpCabalFile lp
                  packageDepsSet = setOfPackageDeps pkg
                  loc = PLMutable $ ResolvedPath (RelFilePath "N/A") pkgDir
              in  (packageName pkg, (deps pkg packageDepsSet, lpPayload pkg loc)))
      locals
 where
  deps pkg packageDepsSet = if dotIncludeExternal dotOpts
    then Set.delete (packageName pkg) packageDepsSet
    else Set.intersection localNames packageDepsSet
  localNames = Set.fromList $ map (packageName . lpPackage) locals
  lpPayload pkg loc =
    DotPayload (Just $ packageVersion pkg)
               (Just $ packageLicense pkg)
               (Just loc)

-- | Given a SourceMap and a dependency loader, load the set of dependencies for
-- a package
createDepLoader ::
     SourceMap
  -> Map PackageName DumpPackage
  -> Map GhcPkgId PackageIdentifier
  -> (  PackageName
     -> Version
     -> PackageLocationImmutable
     -> Map FlagName Bool
     -> [Text]
     -> [Text]
     -> RIO DotConfig (Set PackageName, DotPayload)
     )
  -> PackageName
  -> RIO DotConfig (Set PackageName, DotPayload)
createDepLoader sourceMap globalDumpMap globalIdMap loadPackageDeps pkgName =
  fromMaybe (throwIO $ PackageNotFoundBug pkgName)
    (projectPackageDeps <|> dependencyDeps <|> globalDeps)
 where
  projectPackageDeps = loadDeps <$> Map.lookup pkgName (smProject sourceMap)
   where
    loadDeps pp = do
      pkg <- loadCommonPackage (ppCommon pp)
      pure (setOfPackageDeps pkg, payloadFromLocal pkg Nothing)

  dependencyDeps =
    loadDeps <$> Map.lookup pkgName (smDeps sourceMap)
   where
    loadDeps DepPackage{dpLocation=PLMutable dir} = do
      pp <- mkProjectPackage YesPrintWarnings dir False
      pkg <- loadCommonPackage (ppCommon pp)
      pure (setOfPackageDeps pkg, payloadFromLocal pkg (Just $ PLMutable dir))

    loadDeps dp@DepPackage{dpLocation=PLImmutable loc} = do
      let common = dpCommon dp
      gpd <- liftIO $ cpGPD common
      let PackageIdentifier name version = PD.package $ PD.packageDescription gpd
          flags = cpFlags common
          ghcOptions = cpGhcOptions common
          cabalConfigOpts = cpCabalConfigOpts common
      assert
        (pkgName == name)
        (loadPackageDeps pkgName version loc flags ghcOptions cabalConfigOpts)

  -- If package is a global package, use info from ghc-pkg (#4324, #3084)
  globalDeps =
    pure . getDepsFromDump <$> Map.lookup pkgName globalDumpMap
   where
    getDepsFromDump dump = (Set.fromList deps, payloadFromDump dump)
     where
      deps = map ghcIdToPackageName (dpDepends dump)
      ghcIdToPackageName depId =
        maybe (impureThrow $ DependencyNotFoundBug depId)
              Stack.Prelude.pkgName
              (Map.lookup depId globalIdMap)

  payloadFromLocal pkg =
    DotPayload (Just $ packageVersion pkg) (Just $ packageLicense pkg)

  payloadFromDump dp =
    DotPayload (Just $ pkgVersion $ dpPackageIdent dp)
               (Right <$> dpLicense dp)
               Nothing

-- | Resolve the dependency graph up to (Just depth) or until fixpoint is reached
resolveDependencies ::
     (Applicative m, Monad m)
  => Maybe Int
  -> Map PackageName (Set PackageName, DotPayload)
  -> (PackageName -> m (Set PackageName, DotPayload))
  -> m (Map PackageName (Set PackageName, DotPayload))
resolveDependencies (Just 0) graph _ = pure graph
resolveDependencies limit graph loadPackageDeps = do
  let values = Set.unions (fst <$> Map.elems graph)
      keys = Map.keysSet graph
      next = Set.difference values keys
  if Set.null next
     then pure graph
     else do
       x <- T.traverse (\name -> (name,) <$> loadPackageDeps name) (F.toList next)
       resolveDependencies (subtract 1 <$> limit)
                      (Map.unionWith unifier graph (Map.fromList x))
                      loadPackageDeps
 where
  unifier (pkgs1,v1) (pkgs2,_) = (Set.union pkgs1 pkgs2, v1)

-- | @pruneGraph dontPrune toPrune graph@ prunes all packages in
-- @graph@ with a name in @toPrune@ and removes resulting orphans
-- unless they are in @dontPrune@
pruneGraph ::
     (F.Foldable f, F.Foldable g, Eq a)
  => f PackageName
  -> g PackageName
  -> Map PackageName (Set PackageName, a)
  -> Map PackageName (Set PackageName, a)
pruneGraph dontPrune names =
  pruneUnreachable dontPrune . Map.mapMaybeWithKey (\pkg (pkgDeps,x) ->
    if pkg `F.elem` names
      then Nothing
      else let filtered = Set.filter (`F.notElem` names) pkgDeps
           in  if Set.null filtered && not (Set.null pkgDeps)
                 then Nothing
                 else Just (filtered,x))

-- | Make sure that all unreachable nodes (orphans) are pruned
pruneUnreachable ::
     (Eq a, F.Foldable f)
  => f PackageName
  -> Map PackageName (Set PackageName, a)
  -> Map PackageName (Set PackageName, a)
pruneUnreachable dontPrune = fixpoint prune
 where
  fixpoint :: Eq a => (a -> a) -> a -> a
  fixpoint f v = if f v == v then v else fixpoint f (f v)
  prune graph' = Map.filterWithKey (\k _ -> reachable k) graph'
   where
    reachable k = k `F.elem` dontPrune || k `Set.member` reachables
    reachables = F.fold (fst <$> graph')

localPackageToPackage :: LocalPackage -> Package
localPackageToPackage lp =
  fromMaybe (lpPackage lp) (lpTestBench lp)

data DotConfig = DotConfig
  { dcBuildConfig :: !BuildConfig
  , dcSourceMap :: !SourceMap
  , dcGlobalDump :: ![DumpPackage]
  }

instance HasLogFunc DotConfig where
  logFuncL = runnerL.logFuncL

instance HasPantryConfig DotConfig where
  pantryConfigL = configL.pantryConfigL

instance HasTerm DotConfig where
  useColorL = runnerL.useColorL
  termWidthL = runnerL.termWidthL

instance HasStylesUpdate DotConfig where
  stylesUpdateL = runnerL.stylesUpdateL

instance HasGHCVariant DotConfig where
  ghcVariantL = configL.ghcVariantL
  {-# INLINE ghcVariantL #-}

instance HasPlatform DotConfig where
  platformL = configL.platformL
  {-# INLINE platformL #-}
  platformVariantL = configL.platformVariantL
  {-# INLINE platformVariantL #-}

instance HasRunner DotConfig where
  runnerL = configL.runnerL

instance HasProcessContext DotConfig where
  processContextL = runnerL.processContextL

instance HasConfig DotConfig where
  configL = buildConfigL.lens bcConfig (\x y -> x { bcConfig = y })
  {-# INLINE configL #-}

instance HasBuildConfig DotConfig where
  buildConfigL = lens dcBuildConfig (\x y -> x { dcBuildConfig = y })

instance HasSourceMap DotConfig where
  sourceMapL = lens dcSourceMap (\x y -> x { dcSourceMap = y })
