{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
module Stack.BuildPlanSpec where

import Stack.BuildPlan
import Control.Monad.Logger
import Control.Monad.IO.Unlift
import Data.Monoid
import qualified Data.Map as Map
import qualified Data.Set as Set
import Prelude -- Fix redundant import warnings
import System.Directory
import System.Environment
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Stack.Config
import Stack.Types.BuildPlan
import Stack.Types.Compiler
import Stack.Types.PackageName
import Stack.Types.Version
import Stack.Types.Config
import Stack.Types.Compiler
import Stack.Types.StackT

setup :: IO ()
setup = unsetEnv "STACK_YAML"

main :: IO ()
main = hspec spec

spec :: Spec
spec = beforeAll setup $ do
    return ()
    {- FIXME
    let logLevel = LevelDebug
    let loadConfig' = runStackT () logLevel True False ColorAuto False (loadConfig mempty Nothing SYLDefault)
    let loadBuildConfigRest = runStackT () logLevel True False ColorAuto False
    let inTempDir action = do
            currentDirectory <- getCurrentDirectory
            withSystemTempDirectory "Stack_BuildPlanSpec" $ \tempDir -> do
                let enterDir = setCurrentDirectory tempDir
                let exitDir = setCurrentDirectory currentDirectory
                bracket_ enterDir exitDir action
    it "finds missing transitive dependencies #159" $ inTempDir $ do
        -- Note: this test is somewhat fragile, depending on packages on
        -- Hackage remaining in a certain state. If it fails, confirm that
        -- github still depends on failure.
        writeFile "stack.yaml" "resolver: lts-2.9"
        LoadConfig{..} <- loadConfig'
        bconfig <- loadBuildConfigRest (lcLoadBuildConfig Nothing)
        runStackT bconfig logLevel True False ColorAuto False $ do
            mbp <- loadMiniBuildPlan $ LTS 2 9
            eres <- try $ resolveBuildPlan
                mbp
                (const False)
                (Map.fromList
                    [ ($(mkPackageName "github"), Set.empty)
                    ])
            case eres of
                Left (UnknownPackages _ unknown _) -> do
                    case Map.lookup $(mkPackageName "github") unknown of
                        Nothing -> error "doesn't list github as unknown"
                        Just _ -> return ()

                    {- Currently not implemented, see: https://github.com/fpco/stack/issues/159#issuecomment-107809418
                    case Map.lookup $(mkPackageName "failure") unknown of
                        Nothing -> error "failure not listed"
                        Just _ -> return ()
                    -}
                _ -> error $ "Unexpected result from resolveBuildPlan: " ++ show eres
            return ()
    -}

    {- FIXME
    describe "shadowMiniBuildPlan" $ do
        let version = $(mkVersion "1.0.0") -- unimportant for this test
            pn = either throw id . parsePackageNameFromString
            mkMPI deps = LoadedPackageInfo
                { lpiVersion = version
                , lpiLocation = PLIndex $ PackageIdentifierRevision
                    (PackageIdentifier pn version)
                    Nothing
                , lpiFlags = Map.empty
                , lpiGhcOptions = []
                , lpiPackageDeps = Set.fromList $ map pn $ words deps
                , lpiProvidedExes = Set.empty
                , lpiNeededExes = Map.empty
                , lpiExposedModules = Set.empty
                , lpiHide = False
                }
            go x y = (pn x, mkMPI y)
            resourcet = go "resourcet" ""
            conduit = go "conduit" "resourcet"
            conduitExtra = go "conduit-extra" "conduit"
            text = go "text" ""
            attoparsec = go "attoparsec" "text"
            aeson = go "aeson" "text attoparsec"
            mkMBP pkgs = LoadedSnapshot
                { lsCompilerVersion = GhcVersion version
                , lsPackages = Map.fromList pkgs
                , lsResolver = ResolverCompiler $ GhcVersion version
                }
            mbpAll = mkMBP [resourcet, conduit, conduitExtra, text, attoparsec, aeson]
            test name input shadowed output extra =
                it name $ const $
                    shadowMiniBuildPlan input (Set.fromList $ map pn $ words shadowed)
                    `shouldBe` (output, Map.fromList extra)
        test "no shadowing" mbpAll "" mbpAll []
        test "shadow something that isn't there" mbpAll "does-not-exist" mbpAll []
        test "shadow a leaf" mbpAll "conduit-extra"
                (mkMBP [resourcet, conduit, text, attoparsec, aeson])
                []
        test "shadow direct dep" mbpAll "conduit"
                (mkMBP [resourcet, text, attoparsec, aeson])
                [conduitExtra]
        test "shadow deep dep" mbpAll "resourcet"
                (mkMBP [text, attoparsec, aeson])
                [conduit, conduitExtra]
        test "shadow deep dep and leaf" mbpAll "resourcet aeson"
                (mkMBP [text, attoparsec])
                [conduit, conduitExtra]
        test "shadow deep dep and direct dep" mbpAll "resourcet conduit"
                (mkMBP [text, attoparsec, aeson])
                [conduitExtra]
    -}
