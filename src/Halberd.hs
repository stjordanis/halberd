{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE ImplicitParams       #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE TupleSections        #-}

import           Control.Applicative
import           Control.Arrow
import           Control.Monad
import           Data.Function
import           Data.List
import           Data.Maybe
import           Data.Map                            (Map)
import qualified Data.Map                            as Map
import           Data.Monoid
import           Data.Ord
import           Data.Proxy
import           Data.Set                            (Set)
import qualified Data.Set                            as Set
import           Distribution.HaskellSuite
import qualified Distribution.InstalledPackageInfo   as Cabal
import qualified Distribution.ModuleName             as Cabal
import qualified Distribution.Package                as Cabal
import           Distribution.Simple.Compiler
import qualified Distribution.Text                   as Cabal
import           Language.Haskell.Exts.Annotated
import           Language.Haskell.Names
import           Language.Haskell.Names.Imports      ()
import           Language.Haskell.Names.Interfaces
import           System.Environment
import           System.Exit

import           Halberd.CollectNames                (collectUnboundNames)

main :: IO ()
main =
  do args <- getArgs
     case args of
       [] -> do
         putStrLn "Usage: halberd <SOURCEFILE>"
         exitFailure
       (file:_) -> do
         (ParseOk module_) <- parseFile file
         pkgs <- concat <$>
           mapM
             (getInstalledPackages (Proxy :: Proxy NamesDB))
             [UserPackageDB, GlobalPackageDB]
         bla <- evalModuleT (suggestedImports module_) pkgs suffix readInterface
         putStrLn bla
  where
    suffix = "names"

type CanonicalSymbol a = (PackageRef, Cabal.ModuleName, a OrigName)

data PackageRef = PackageRef
  { installedPackageId :: Cabal.InstalledPackageId
  , sourcePackageId    :: Cabal.PackageId
  } deriving (Eq, Ord, Show)

toPackageRef :: Cabal.InstalledPackageInfo_ m -> PackageRef
toPackageRef pkgInfo =
    PackageRef { installedPackageId = Cabal.installedPackageId pkgInfo
               , sourcePackageId    = Cabal.sourcePackageId    pkgInfo
               }

suggestedImports :: Module SrcSpanInfo -> ModuleT Symbols IO String
suggestedImports module_ =
  do pkgs <- getPackages
     annSrc <- annotateModule Haskell98 [] (fmap srcInfoSpan module_)
     let (typeNames, valueNames) = collectUnboundNames annSrc
     (valueDefs, typeDefs) <-
       fmap mconcat $ forM pkgs $ \pkg ->
         fmap mconcat $ forM (Cabal.exposedModules pkg) $ \exposedModule -> do
            (Symbols values types) <- readModuleInfo (Cabal.libraryDirs pkg) exposedModule
            return (Set.map (toPackageRef pkg, exposedModule,) values, Set.map (toPackageRef pkg, exposedModule,) types)
     let valueTable = toLookupTable (gUnqual . sv_origName . trd) valueDefs
         typeTable  = toLookupTable (gUnqual . st_origName . trd) typeDefs
     return $ (unlines $ nub $ map (toImportStatements "value" valueTable) valueNames)
              ++ (unlines $ nub $ map (toImportStatements "type" typeTable) typeNames)
  where
    trd (_, _, z)        = z
    gUnqual (OrigName _ (GName _ n))  = n


lookupDefinitions :: Map String [CanonicalSymbol a] -> QName (Scoped SrcSpan) -> [CanonicalSymbol a]
lookupDefinitions symbolTable qname = fromMaybe [] $
  do n <- unQName qname
     Map.lookup n symbolTable
  where
    unQName (Qual    _ _ n) = Just (strName n)
    unQName (UnQual  _   n) = Just (strName n)
    unQName (Special _ _  ) = Nothing

    strName (Ident  _ str)  = str
    strName (Symbol _ str)  = str


mkImport :: QName a -> CanonicalSymbol b -> String
mkImport qname (_, moduleName, _) =
  case qname of
    Qual _ qualification _ -> intercalate " "
      [ "import"
      , "qualified"
      , Cabal.display moduleName
      , "as"
      , prettyPrint qualification
      ]
    UnQual _ n -> intercalate " "
      [ "import"
      , Cabal.display moduleName
      , "("
      , prettyPrint n
      , ")"
      ]
    Special _ _ -> error "impossible: toImportStatements"

toImportStatements :: Show (a OrigName) => String
                   -> Map String [(CanonicalSymbol a)]
                   -> QName (Scoped SrcSpan)
                   -> String
toImportStatements nameSpace symbolTable qname = unlines $ case lookupDefinitions symbolTable qname of
    []   -> ["-- Could not find " ++ nameSpace ++ ": " ++ prettyPrint qname]
    defs -> map (mkImport qname) defs


toLookupTable :: Ord k => (a -> k) -> Set a -> Map k [a]
toLookupTable key = Map.fromList
                  . map (fst . head &&& map snd)
                  . groupBy ((==) `on` fst)
                  . sortBy (comparing fst)
                  . map (key &&& id)
                  . Set.toList
