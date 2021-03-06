{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module Main where

import Control.Monad
import qualified Language.Thrift.Parser as T
import qualified Language.Thrift.AST as T
import System.Console.GetOpt (getOpt, usageInfo, ArgOrder(..), OptDescr(..), ArgDescr(..))
import System.Environment (getArgs)
import System.FilePath
import System.Directory
import qualified Language.Haskell.Exts as H
import qualified Data.IntMap.Strict as IM
import qualified Data.Text as T
import Data.Text (Text)
import Data.List (find, foldl', intercalate)
import Data.Char (toUpper)
import Text.Casing (pascal, camel)

--------------------------------------------------------------------------------

data CompileOpt = CompileOpt
        { cOptLensy :: Bool
        , cOptLazy :: Bool
        , cOptShowVersion :: Bool
        , cOptOutput :: String
        } deriving Show

defaultCompileOpt = CompileOpt
    { cOptLensy = False
    , cOptLazy  = False
    , cOptShowVersion = False
    , cOptOutput = ""
    }

main :: IO ()
main = do
    (opt, ps) <- getArgs >>= compilerOpts
    if cOptShowVersion opt
    then putStrLn "Version: thrift-haskell-compiler 0.1.0.0"
    else do
        cwd <- getCurrentDirectory
        compileAll cwd opt ps
  where
    options :: [OptDescr (CompileOpt -> CompileOpt)]
    options =
        [ Option ['V','?'] ["version"]
            (NoArg (\ opts -> opts { cOptShowVersion = True }))
            "show version number"
        , Option ['l'] ["lens"]
            (NoArg (\ opts -> opts { cOptLensy = True}))
            "make lense for record fields"
        , Option ['z'] ["lazy"]
            (NoArg (\ opts -> opts { cOptLazy = True}))
            "use lazy fields in data declarations"
        , Option ['o'] ["output"]
            (ReqArg (\ str opts -> opts { cOptOutput = str }) "path")
            "output path"
        ]
    compilerOpts :: [String] -> IO (CompileOpt, [String])
    compilerOpts argv = case getOpt Permute options argv of
        (o,n,[]  ) -> return (foldl (flip id) defaultCompileOpt o, n)
        (_,_,errs) -> ioError (userError (concat errs ++ usageInfo usage options))
    usage = "Usage: thrift-haskell-compiler [OPTION...] files/dirs..."

    compileAll :: FilePath -> CompileOpt -> [FilePath] -> IO ()
    compileAll cwd opt ps =
        forM_ ps $ \ p -> do
            isFile <- doesFileExist p
            if isFile
            then compile cwd opt p
            else compileAll cwd opt . map (p </>) =<< listDirectory p

--------------------------------------------------------------------------------

compile :: FilePath     -- root directory
        -> CompileOpt   -- compile options
        -> FilePath     -- IDL file
        -> IO ()        -- compile and save
compile root opt p = do
    let p' = normalise $ cOptOutput opt </> p
        relPath = makeRelative root p'

    T.parseFromFile p >>= \ case
        Left e -> putStrLn $ "parse " ++ p ++ " failed with: " ++ show e
        Right (T.Program headers defs) -> do
            let moduleSpec = mkModuleSpec relPath
                imports = findImports (msPrefix moduleSpec) headers
                dels = compileDefs defs
                moduleHead = H.ModuleHead ()
                            (toModuleName moduleSpec)
                            Nothing
                            Nothing

                module_ = H.Module () (Just moduleHead)
                        defaultPragmas
                        (defaultImports ++ map toImportDel imports)
                        dels

            let hs = H.prettyPrintWithMode H.defaultMode module_
                output = toOutputPath moduleSpec

            createDirectoryIfMissing True $ takeDirectory output
            writeFile output hs
  where
    -- Find all imports from thrift include
    findImports :: [String] -> [T.Header a] -> [ModuleSpec]
    findImports prefix = foldr go []
      where
        go x acc = case x of
            T.HeaderInclude (T.Include p _) -> mkImportModuleSpec prefix p:acc
            _                               -> acc

    -- Compile all thrift definitions into a export list and a declaration list.
    compileDefs :: [T.Definition a] -> [H.Decl ()]
    compileDefs = concatMap (compileTDef opt)

    -- Default enabled pragmas
    defaultPragmas :: [H.ModulePragma ()]
    defaultPragmas = [ hPragma "RecordWildCards"
                     , hPragma "DeriveGeneric"
                     , hPragma "DeriveAnyClass"
                     , hPragma "DeriveDataTypeable"
                     , hPragma "OverloadedStrings"
                     ]

    hPragma s = H.LanguagePragma () [H.Ident () s]

    -- Default imports
    defaultImports :: [H.ImportDecl ()]
    defaultImports = [ hImport "Thrift.Type" "Thrift"
                     , hImport "Control.Exception" "Exception"
                     , hImport "Data.Maybe" "Maybe"
                     ]

    hImport mod alias =
        H.ImportDecl () (H.ModuleName () mod) True False False Nothing
                     (Just (H.ModuleName () alias)) Nothing


--------------------------------------------------------------------------------

data ModuleSpec = ModuleSpec
    { msPrefix :: [String] -- ^ the prefix of the module name
    , msName :: String     -- ^ the last part of module name, we also use it as import alias
    }

-- | Join ModuleSpec into a module name string.
toOutputPath :: ModuleSpec -> FilePath
toOutputPath (ModuleSpec prefix name) = foldr (</>) name prefix `addExtension` "hs"

-- | Join ModuleSpec into a module name string.
toImportDel :: ModuleSpec -> H.ImportDecl ()
toImportDel ms@(ModuleSpec prefix name) =
    H.ImportDecl () (toModuleName ms) True False False Nothing
                 (Just $ H.ModuleName () name) Nothing

-- | Join ModuleSpec into a module name string.
toModuleName :: ModuleSpec -> H.ModuleName ()
toModuleName (ModuleSpec prefix name) =
    H.ModuleName () $ concatMap (++ ".") prefix ++ name

-- | Make moduleName from a relative 'FilePath'.
mkModuleSpec :: FilePath -> ModuleSpec
mkModuleSpec fp = let ps = splitDirectories (dropExtension fp)
                  in ModuleSpec (pascal <$> init ps) (pascal $ last ps)


-- | Make moduleName from a include path with current prefix.
mkImportModuleSpec :: [String] -> Text -> ModuleSpec
mkImportModuleSpec prefix fp = let ps = splitDirectories (dropExtension (T.unpack fp))
                                   prefix' = pascal <$> init ps
                                   name = pascal $ last ps
                               in ModuleSpec (prefix ++ prefix') name


--------------------------------------------------------------------------------

compileTDef :: CompileOpt -> T.Definition a -> [H.Decl ()]
compileTDef _ (T.ConstDefinition T.Const{..}) =
    [   H.TypeSig () [mkName constName] (mkType constValueType)
    ,   H.nameBind (mkName constName) (mkConstExp constValue)
    ]

compileTDef _ (T.TypeDefinition (T.TypedefType T.Typedef{..})) =
    [   H.TypeDecl ()
            (H.DHead () (mkCapName typedefName))
            (mkType typedefTargetType)
    ]
compileTDef _ (T.TypeDefinition (T.EnumType T.Enum{..})) =
    [ H.DataDecl () (H.DataType ()) Nothing
        (H.DHead () (mkCapName enumName))
        ((`map` enumValues) $ \ T.EnumDef{..} ->
            H.QualConDecl () Nothing Nothing
                (H.ConDecl () (mkCapName enumDefName) [])
        )
        (Just (H.Deriving ()
            [ mkDerivingInst "Eq"
            , mkDerivingInst "Ord"
            , mkDerivingInst "Show"
            , mkDerivingInst "Enum"
            , mkDerivingInst "Bounded"
            , mkDerivingInst "Thrift.Data"
            , mkDerivingInst "Thrift.Typeable"
            , mkDerivingInst "Thrift.Generic"
            , mkDerivingInst "Thrift.Hashable"
            ]))
    , H.InstDecl () Nothing (mkSimpleClassInst "Thrift.Thrift" (mkTypeConT enumName))
        (Just
            [ H.InsDecl () $ H.sfun (H.name "typeCode") []
                (H.UnGuardedRhs ()
                    (H.metaFunction "Thrift.TypeCodeTagged" [H.var $ H.name "Thrift.TC_Int32"]))
                Nothing
            , H.InsDecl () $ H.sfun (H.name "defaultValue") []
                (H.UnGuardedRhs () (H.var . mkCapName . T.enumDefName . head $ enumValues))
                Nothing
            , H.InsDecl () . H.FunBind () $ (`map` enums) $ \ (n, v) ->
                toTValueMatch
                    [H.PApp () (unQual n) []]
                    (H.UnGuardedRhs () $ tInt32Exp v) Nothing
            , H.InsDecl () . H.FunBind () $ ((`map` enums) $ \ (n, v) ->
                fromTValueMatch
                    [tInt32Pat v]   -- pattern match enum
                    (H.UnGuardedRhs () (H.var n)) Nothing
                ) ++ [ fromTValueMatch
                        [H.wildcard]   -- pattern match enum
                        (H.UnGuardedRhs ()
                            (H.metaFunction "error" [H.strE "bad enum value"]))
                            Nothing
                    ]
            ])
    ]
  where
    enums = zip (map (mkCapName .T.enumDefName) enumValues) enumDefValues
    enumDefValues = tail . reverse $ foldl' getValue [-1] (map T.enumDefValue enumValues)
    getValue acc@(x:xs) Nothing = (x + 1):acc
    getValue acc (Just x') = x' : acc

compileTDef cOpt (T.TypeDefinition (T.StructType struct@T.Struct{..})) = case structFields of
    -- use '()' as empty request
    []      -> [ H.TypeDecl () (H.DHead () sName) unitType ]
    -- use record for a non empty struct
    sFields -> case structKind of
        -- struct
        T.StructKind ->
            [ H.DataDecl () (H.DataType ()) Nothing
                (H.DHead () sName)
                    [ H.QualConDecl () Nothing Nothing . H.RecDecl () sName $
                        (`map` sFields) $ \ T.Field{..} ->
                            H.FieldDecl () [mkName $ T.concat [structName, "_", fieldName]]
                                (mkFieldType fieldRequiredness fieldValueType)
                    ]
                    (Just (H.Deriving ()
                        [ mkDerivingInst "Eq"
                        , mkDerivingInst "Show"
                        , mkDerivingInst "Thrift.Data"
                        , mkDerivingInst "Thrift.Typeable"
                        , mkDerivingInst "Thrift.Generic"
                        , mkDerivingInst "Thrift.Hashable"
                        ]))
            , H.InstDecl () Nothing (mkSimpleClassInst "Thrift.Thrift" (mkTypeConT structName))
                (Just
                    [ H.InsDecl () $ H.sfun (H.name "typeCode") []
                        (H.UnGuardedRhs ()
                            (H.metaFunction "Thrift.TypeCodeTagged" [H.var $ H.name "Thrift.TC_Struct"]))
                        Nothing
                    , H.InsDecl () $ H.sfun (H.name "defaultValue") []
                        (H.UnGuardedRhs () $ H.letE ((`map` sFields) $ \ T.Field{..} ->
                            H.patBind
                                (H.pvar . mkName $ T.concat [structName, "_", fieldName])
                                (case fieldDefaultValue of
                                    Nothing -> H.var . H.name $ case fieldRequiredness of
                                        Just T.Optional -> "Nothing"
                                        _               -> "Thrift.defaultValue"
                                    Just d  -> case fieldRequiredness of
                                        Just T.Optional ->
                                            H.metaFunction "Just" [mkConstExp d]
                                        _ -> mkConstExp d
                                )
                            )
                            sExp
                        )
                        Nothing
                    , H.InsDecl () . H.FunBind () $
                        [ toTValueMatch
                            [sPat]
                            (H.UnGuardedRhs () . tStructExp . H.metaFunction "Maybe.catMaybes" $
                                [ H.List () $ (`map` sFields) $ \ T.Field{..} ->
                                    let n = camel . T.unpack . T.concat $ [structName, "_", fieldName]
                                    in case fieldIdentifier of
                                        Nothing -> error $ "can't find field identifier for " ++ n
                                        Just fid ->
                                            case fieldRequiredness of
                                                Just T.Optional ->
                                                    H.caseE (H.var $ H.name n)
                                                        [ H.alt (H.metaConPat "Just" [H.pvar $ H.name "x"]) $
                                                            H.metaFunction "Just"
                                                                [ H.tuple
                                                                    [ H.intE fid
                                                                    , toTValueFun (H.var $ H.name "x")
                                                                    ]
                                                                ]
                                                        , H.alt H.wildcard (H.var $ H.name "Nothing")
                                                        ]
                                                _ ->
                                                    H.metaFunction "Just"
                                                        [ H.tuple
                                                            [ H.intE fid
                                                            , toTValueFun (H.var $ H.name n)
                                                            ]
                                                        ]
                                ]
                            )
                            Nothing
                        ]
                    , H.InsDecl () . H.FunBind () $
                        let mPat = H.pvar $ H.name "m"
                            mExp = H.var $ H.name "m"
                            xPat = H.pvar $ H.name "x"
                            xExp = H.var $ H.name "x"
                        -- convert to 'IM.IntMap' first, then use 'Maybe' monad
                        in [ fromTValueMatch [tStructPat xPat]  -- pattern match kv list
                            (H.UnGuardedRhs () . H.letE
                                (H.patBind mPat (H.metaFunction "Thrift.mkIntMap" [xExp]) :
                                    ((`map` sFields) $ \ T.Field{..} ->
                                        let n = camel . T.unpack . T.concat $ [structName, "_", fieldName]
                                            -- how 'T.FieldRequiredness' affect deserialization
                                            lookupFunc = case (fieldRequiredness, fieldDefaultValue) of
                                                -- default field
                                                (Nothing, Nothing) ->
                                                    H.metaFunction "Thrift.lookupDefault" .
                                                        (H.var (H.name "Thrift.defaultValue") :)
                                                (Nothing, Just d) ->
                                                    H.metaFunction "Thrift.lookupDefault" .
                                                        (mkConstExp d :)
                                                (Just T.Optional, Nothing) ->
                                                    H.metaFunction "Thrift.lookupOptional" .
                                                        (H.var (H.name "Nothing") :)
                                                (Just T.Optional, Just d) ->
                                                    H.metaFunction "Thrift.lookupOptional" .
                                                        (H.metaFunction "Just" [mkConstExp d] :)
                                                (Just T.Required, _) ->
                                                    H.metaFunction "Thrift.lookupRequired"

                                        in case fieldIdentifier of
                                            Nothing -> error $ "can't find field identifier for " ++ n
                                            Just fid ->
                                                H.patBind (H.pvar $ H.name n)
                                                    (lookupFunc [ H.intE fid , mExp ])
                                    )
                                ) $ sExp
                            )
                            Nothing
                        , fromTValueMatch
                            [H.wildcard]   -- pattern match enum
                            (H.UnGuardedRhs ()
                                (H.metaFunction "error" [H.strE "bad struct value"]))
                            Nothing
                        ]
                    ])
            ]
        T.ExceptionKind ->
            let struct' = struct{ T.structKind = T.StructKind }
                defs = compileTDef cOpt (T.TypeDefinition (T.StructType struct'))
            in defs ++ [
                H.InstDecl () Nothing
                    (mkSimpleClassInst "Exception.Exception" (mkTypeConT structName))
                    Nothing
            ]
        T.UnionKind ->
            let fields = (`map` sFields) $ \ f@T.Field{..} ->
                    (mkCapName $ T.concat [structName, "_", fieldName], f)
            in [ H.DataDecl () (H.DataType ()) Nothing
                    (H.DHead () sName)
                    ((`map` fields) $ \ (fname, T.Field{..}) ->
                        H.QualConDecl () Nothing
                            Nothing (H.ConDecl () fname [mkType fieldValueType])
                    )
                    (Just (H.Deriving ()
                        [ mkDerivingInst "Eq"
                        , mkDerivingInst "Show"
                        , mkDerivingInst "Thrift.Data"
                        , mkDerivingInst "Thrift.Typeable"
                        , mkDerivingInst "Thrift.Generic"
                        , mkDerivingInst "Thrift.Hashable"
                        ]))
            , H.InstDecl () Nothing (mkSimpleClassInst "Thrift.Thrift" (mkTypeConT structName))
                (Just
                    [ H.InsDecl () $ H.sfun (H.name "typeCode") []
                        (H.UnGuardedRhs ()
                            (H.metaFunction "Thrift.TypeCodeTagged" [H.var $ H.name "Thrift.TC_Struct"]))
                        Nothing
                    , H.InsDecl () $ H.sfun (H.name "defaultValue") []
                        (H.UnGuardedRhs ()
                            (H.app (H.var . fst $ head fields)
                                (H.var $ H.name "Thrift.defaultValue"))
                        )
                        Nothing
                    , H.InsDecl () . H.FunBind () . (`map` fields) $ \ (n, T.Field{..}) ->
                        case fieldIdentifier of
                            Nothing -> error $ "can't find field identifier for " ++
                                        T.unpack fieldName
                            Just fid ->
                                let xPat = H.pvar $ H.name "x"
                                    xExp = H.var $ H.name "x"
                                in toTValueMatch
                                    [H.PApp () (unQual n) [xPat]]
                                    (H.UnGuardedRhs () . tStructExp . H.listE $ [
                                        H.tuple [ H.intE fid
                                                , H.metaFunction "Thrift.toTValue" [xExp]
                                                ]
                                    ])
                                    Nothing
                    , let mPat = H.pvar $ H.name "m"
                          mExp = H.var $ H.name "m"
                          mPat' = H.pvar $ H.name "m'"
                          mExp' = H.var $ H.name "m'"
                          xPat = H.pvar $ H.name "x"
                          xExp = H.var $ H.name "x"
                      in H.InsDecl () $ H.FunBind ()
                        [ fromTValueMatch
                            [H.pApp (H.name "Thrift.TStruct") [mPat]]
                            (H.GuardedRhss () $ ((`map` fields) $ \ (n, T.Field{..}) ->
                                case fieldIdentifier of
                                    Nothing -> error $ "can't find field identifier for " ++
                                                T.unpack fieldName
                                    Just fid -> H.GuardedRhs ()
                                        [ H.Generator () (H.metaConPat "Just" [xPat]) $
                                            H.metaFunction "Thrift.lookup" [ H.intE fid, mExp' ]
                                        ]
                                        (H.app (H.var n) (fromTValueFun xExp))
                                ) ++ [ H.GuardedRhs () [H.Qualifier () (H.var $ H.name "otherwise")]
                                    (H.metaFunction "error" [H.strE "bad union struct"]) ]
                            )
                            (Just $ H.binds
                                [ H.patBind mPat' $ H.metaFunction "Thrift.mkIntMap" [mExp]
                                ])
                        , fromTValueMatch
                            [H.wildcard]
                            (H.UnGuardedRhs ()
                                (H.metaFunction "error" [H.strE "bad union struct value"]))
                            Nothing
                        ]
                    ])
            ]

  where
    sName = mkCapName structName
    -- we rely on @RecordWildCards@ to simplify naming
    sPat = H.PRec () (unQual sName) [H.PFieldWildcard ()]
    sExp = H.RecConstr () (unQual sName) [H.FieldWildcard ()]
    fieldIdentifier = tail . reverse $ foldl' getValue [-1] (map T.fieldIdentifier structFields)
    getValue acc@(x:xs) Nothing = (x + 1):acc
    getValue acc (Just x') = x' : acc

compileTDef _ (T.TypeDefinition (T.SenumType T.Senum{..})) = error "compileTDef: senum is deprecated"

compileTDef cOpt (T.ServiceDefinition T.Service{..}) =
    ((`concatMap` serviceFunctions) $ \ T.Function{..} ->
        let n = T.concat [serviceName, "_", functionName]
            fname = mkName n
            -- use unitType as thrift void
            returnType = maybe unitType mkType functionReturnType
        in concat [
            -- use struct to present request
            let reqStruct = T.Struct {
                    T.structName = n `T.append` "Req"
                ,   T.structFields = functionParameters
                ,   T.structAnnotations = []
                ,   T.structDocstring = functionDocstring  -- unused
                ,   T.structSrcAnnot = functionSrcAnnot    -- unused
                ,   T.structKind = T.StructKind
                }
            in compileTDef cOpt (T.TypeDefinition (T.StructType reqStruct))

            -- use struct to present respond
        ,   let resFields = case functionReturnType of
                    Nothing      ->  []
                    Just retType -> [
                        T.Field {   -- return value is taken as field 0
                                    T.fieldIdentifier = Just 0
                                    -- return value is taken as default field
                                ,   T.fieldRequiredness = Nothing
                                ,   T.fieldValueType = retType
                                    -- no field name to void collision with exception fields
                                ,   T.fieldName = ""
                                    -- return value doesn't have default value
                                ,   T.fieldDefaultValue = Nothing
                                ,   T.fieldAnnotations = [] -- unused
                                ,   T.fieldDocstring = functionDocstring -- unused
                                ,   T.fieldSrcAnnot = functionSrcAnnot -- unused
                        }]

                expFields = case functionExceptions of Nothing -> []
                                                       Just es -> es

                resStruct = T.Struct {
                            T.structName = n `T.append` "Res"
                        ,   T.structFields = resFields ++ expFields
                        ,   T.structAnnotations = []
                        ,   T.structDocstring = functionDocstring      -- unused
                        ,   T.structSrcAnnot = functionSrcAnnot        -- unused
                        ,   T.structKind = T.UnionKind
                        }
            in compileTDef cOpt (T.TypeDefinition (T.StructType resStruct))

        ,   [ H.TypeSig () [mkName n] $
                mkTypeConT "Thrift.Protocol" -->
                    mkTypeConT "Thrift.Transport" -->
                        mkTypeConT (n `T.append` "Req") -->
                            (ioTypCon $: mkTypeConT (n `T.append` "Res"))

            ]
        ,   [ H.nameBind (mkName n) $ H.metaFunction "Thrift.request"
                 [ H.strE $ T.unpack functionName
                 , if functionOneWay then (H.var $ H.name "True")
                                     else (H.var $ H.name "False")
                 ]
            ]
        ]
    ) ++ let hName = mkCapName $ serviceName `T.append` "Handler"
             sName = mkCapName $ serviceName `T.append` "Server"
    in [ H.DataDecl () (H.DataType ()) Nothing
            (H.DHead () hName)
            [ H.QualConDecl () Nothing Nothing . H.RecDecl () hName $
                (`map` serviceFunctions) $ \ T.Function{..} ->
                    let n = T.concat [serviceName, "_", functionName]
                        reqT = n `T.append` "Req"
                        resT = n `T.append` "Res"
                    in H.FieldDecl () [mkName $ n `T.append` "Handler"]
                        (mkTypeConT reqT -->
                            (ioTypCon $: mkTypeConT resT)
                        )
            ]
            Nothing
    ]

--------------------------------------------------------------------------------

(-->) :: H.Type () -> H.Type () -> H.Type ()
(-->) = H.TyFun ()
infixr 4 -->

($:) :: H.Type () -> H.Type () -> H.Type ()
($:) = H.TyApp ()
infixl 2 $:

-- | Directly make a 'QName' from 'Name', we never use constructor directly
-- because we just use "X.Y" style 'String'.
unQual :: H.Name () -> H.QName ()
unQual = H.UnQual ()

-- | translate thrift identifier into camelCased
mkName, mkCapName :: Text -> H.Name ()
mkName = H.Ident () . camel . T.unpack
mkCapName = H.Ident () . pascal . T.unpack

mkTypeConT :: Text -> H.Type ()
mkTypeConT = H.TyCon () . unQual . mkCapName

typCon :: String -> H.Type ()
typCon = H.TyCon () . unQual . H.name

mkFieldType :: Maybe T.FieldRequiredness -> T.TypeReference a -> H.Type ()
mkFieldType (Just T.Optional) t = typCon "Maybe" $: mkType t
mkFieldType _ t = mkType t

unitType :: H.Type ()
unitType = typCon "()"

ioType :: H.Type ()
ioType = typCon "IO"

mkDerivingInst :: String -> H.InstRule ()
mkDerivingInst x = H.IRule () Nothing Nothing (H.IHCon () (unQual (H.name x)))

mkSimpleClassInst :: String -> H.Type () -> H.InstRule ()
mkSimpleClassInst x t = H.IRule () Nothing Nothing
    (H.IHApp () (H.IHCon () (unQual (H.name x))) t)

mkType :: T.TypeReference a -> H.Type ()
mkType (T.DefinedType t _  ) = mkTypeConT t
mkType (T.StringType _ _   ) = typCon "Thrift.Text"
mkType (T.BinaryType _ _   ) = typCon "Thrift.ByteString"
mkType (T.SListType _ _    ) = error "mkType: slist is deprecated"
mkType (T.BoolType _ _     ) = typCon "Bool"
mkType (T.ByteType _ _     ) = typCon "Thrift.Int8"
mkType (T.I16Type _ _      ) = typCon "Thrift.Int16"
mkType (T.I32Type _ _      ) = typCon "Thrift.Int32"
mkType (T.I64Type _ _      ) = typCon "Thrift.Int64"
mkType (T.DoubleType _ _   ) = typCon "Double"
mkType (T.MapType kt vt _ _) = typCon "Thrift.HashMap" $: mkType kt $: mkType vt
mkType (T.SetType vt _ _   ) = typCon "Thrift.HashSet" $: mkType vt
mkType (T.ListType vt _ _  ) = H.TyList () (mkType vt)

mkConstExp :: T.ConstValue a -> H.Exp ()
mkConstExp (T.ConstInt i _       ) = H.intE i
mkConstExp (T.ConstFloat d _     ) = H.Lit () (H.Frac () (realToFrac d) (show d))
mkConstExp (T.ConstLiteral t _   ) = H.strE (T.unpack t)
mkConstExp (T.ConstIdentifier i _) = let is = map (pascal . T.unpack) $ T.split (== '.') i
                                         i' = case is of
                                            [datatyp, constr] -> constr
                                            [imp, _, constr]  -> imp ++ "." ++ constr
                                            _ -> error $ "bad const identifier: " ++ T.unpack i
                                     in H.var (H.name i')
mkConstExp (T.ConstList cs _     ) = H.listE (map mkConstExp cs)
mkConstExp (T.ConstMap kvs _     ) = H.metaFunction "Thrift.mkHashMap" [H.listE (map mkKV kvs)]
  where
    mkKV :: (T.ConstValue a, T.ConstValue b) -> H.Exp ()
    mkKV (k, v) = H.tuple [mkConstExp k, mkConstExp v]

--------------------------------------------------------------------------------

tInt32Exp :: Integer -> H.Exp ()
tInt32Exp x = H.App () (H.Con () . unQual $ H.name "Thrift.TInt32") (H.intE x)

tInt32Pat :: Integer -> H.Pat ()
tInt32Pat x = H.PApp () (unQual $ H.name "Thrift.TInt32") [H.intP x]

tStructExp :: H.Exp () -> H.Exp ()
tStructExp x =  H.App () (H.Con () . unQual $ H.name "Thrift.TStruct") x

tStructPat :: H.Pat () -> H.Pat ()
tStructPat x = H.PApp () (unQual $ H.name "Thrift.TStruct") [x]

fromTValueFun :: H.Exp () -> H.Exp ()
fromTValueFun x = H.metaFunction "Thrift.fromTValue" [x]

fromTValueMatch :: [H.Pat ()] -> (H.Rhs ()) -> Maybe (H.Binds ()) -> H.Match ()
fromTValueMatch = H.Match () (H.name "fromTValue")

toTValueFun :: H.Exp () -> H.Exp ()
toTValueFun x = H.metaFunction "Thrift.toTValue" [x]

toTValueMatch :: [H.Pat ()] -> (H.Rhs ()) -> Maybe (H.Binds ()) -> H.Match ()
toTValueMatch = H.Match () (H.name "toTValue")

rightCon :: H.Exp ()
rightCon = H.Con () . unQual $ H.name "Right"

ioTypCon :: H.Type ()
ioTypCon = H.TyCon () . unQual $ H.name "IO"

--------------------------------------------------------------------------------
