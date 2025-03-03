{- |  Agda backend.
Generate bindings to Haskell data types for use in Agda.

Example for abstract syntax generated in Haskell backend:
@@
  newtype Ident = Ident String deriving (Eq, Ord, Show, Read)

  data Def = DFun Type Ident [Arg] [Stm]
    deriving (Eq, Ord, Show, Read)

  data Arg = ADecl Type Ident
    deriving (Eq, Ord, Show, Read)

  data Stm
      = SExp Exp
      | SInit Type Ident Exp
      | SBlock [Stm]
      | SIfElse Exp Stm Stm
    deriving (Eq, Ord, Show, Read)

  data Type = Type_bool | Type_int | Type_double | Type_void
    deriving (Eq, Ord, Show, Read)
@@
This should be accompanied by the following Agda code:
@@
  module <mod> where

  {-# FOREIGN GHC import qualified Data.Text #-}
  {-# FOREIGN GHC import CPP.Abs #-}
  {-# FOREIGN GHC import CPP.Print (printTree) #-}

  data Ident : Set where
    ident : List Char → Ident

  {-# COMPILE GHC Ident = data Ident (Ident) #-}

  data Def : Set where
    dFun : (t : Type) (x : Ident) (as : List Arg) (ss : List Stm) → Def

  {-# COMPILE GHC Def = data Def (DFun) #-}

  data Arg : Set where
    aDecl : (t : Type) (x : Ident) → Arg

  {-# COMPILE GHC Arg = data Arg (ADecl) #-}

  data Stm : Set where
    sExp : (e : Exp) → Stm
    sInit : (t : Type) (x : Ident) (e : Exp) → Stm
    sBlock : (ss : List Stm) → Stm
    sIfElse : (e : Exp) (s s' : Stm) → Stm

  {-# COMPILE GHC Stm = data Stm
    ( SExp
    | SInit
    | SBlock
    | SIfElse
    ) #-}

  data Type : Set where
    typeBool typeInt typeDouble typeVoid : Type

  {-# COMPILE GHC Type = data Type
    ( Type_bool
    | Type_int
    | Type_double
    | Type_void
    ) #-}

  -- Binding the BNFC pretty printers.

  printIdent  : Ident → String
  printIdent (ident s) = String.fromList s

  postulate
    printType    : Type    → String
    printExp     : Exp     → String
    printStm     : Stm     → String
    printArg     : Arg     → String
    printDef     : Def     → String
    printProgram : Program → String

  {-# COMPILE GHC printType    = \ t -> Data.Text.pack (printTree (t :: Type)) #-}
  {-# COMPILE GHC printExp     = \ e -> Data.Text.pack (printTree (e :: Exp))  #-}
  {-# COMPILE GHC printStm     = \ s -> Data.Text.pack (printTree (s :: Stm))  #-}
  {-# COMPILE GHC printArg     = \ a -> Data.Text.pack (printTree (a :: Arg))  #-}
  {-# COMPILE GHC printDef     = \ d -> Data.Text.pack (printTree (d :: Def))  #-}
  {-# COMPILE GHC printProgram = \ p -> Data.Text.pack (printTree (p :: Program)) #-}
@@
-}

{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

#if __GLASGOW_HASKELL__ >= 800
{-# OPTIONS_GHC -fno-warn-unused-top-binds #-}
#endif

module BNFC.Backend.Agda (makeAgda) where

import Prelude'
import Control.Monad.State hiding (when)
import Data.Char
import Data.Function (on)
import Data.Functor  ((<$>))
import qualified Data.List as List
import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.List.NonEmpty as NEList
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (mapMaybe, isJust, fromJust)
import Data.Set (Set)
import qualified Data.Set as Set

import BNFC.CF
import BNFC.Backend.Base           (Backend, mkfile)
import BNFC.Backend.Haskell.HsOpts
import BNFC.Backend.Haskell.Utils  (parserName)
import BNFC.Options                (SharedOptions)
import BNFC.PrettyPrint
import BNFC.Utils                  (replace, when)

type NEList = NEList.NonEmpty

-- | How to print the types of constructors in Agda?

data ConstructorStyle
  = UnnamedArg  -- ^ Simply typed, like @E → S → S → S@.
  | NamedArg    -- ^ Dependently typed, like @(e : E) (s₁ s₂ : S) → S@.

-- | Import the builtin numeric types (content of some token categories)?

data ImportNumeric
  = YesImportNumeric  -- ^ Import the numeric types.
  | NoImportNumeric   -- ^ Don't import the numeric types.
  deriving (Eq)

-- | Entry-point for Agda backend.

makeAgda
  :: String         -- ^ Current time.
  -> SharedOptions  -- ^ Options.
  -> CF             -- ^ Grammar.
  -> Backend
makeAgda time opts cf = do
  -- Generate AST bindings.
  mkfile (agdaASTFile opts) $
    cf2AgdaAST time (agdaASTFileM opts) (absFileM opts) (printerFileM opts) cf
  -- Generate parser bindings.
  mkfile (agdaParserFile opts) $
    cf2AgdaParser time (agdaParserFileM opts) (agdaASTFileM opts) (absFileM opts) (errFileM opts) (happyFileM opts)
      layoutMod
      parserCats
  -- Generate an I/O library for the test parser.
  mkfile (agdaLibFile opts) $
    agdaLibContents (agdaLibFileM opts)
  -- Generate test parser.
  mkfile (agdaMainFile opts) $
    agdaMainContents (agdaMainFileM opts) (agdaLibFileM opts) (agdaASTFileM opts) (agdaParserFileM opts)
      (hasLayout cf)
      entryPoint
  where
  -- | Generate parsers for the following non-terminals.
  --   This includes parsers for 'CoercCat' and 'ListCat'.
  parserCats :: [Cat]
  parserCats =  allEntryPoints cf
  -- | Entrypoint for test parser:
  entryPoint :: Cat
  entryPoint = case parserCats of
    (c:_) -> c
    _     -> error $ "impossible: makeAgda.entryPoint: allEntryPoints cannot be empty"
    -- cannot be empty
  -- | In case the grammar makes use of layout, pass also the generated layout Haskell module.
  layoutMod :: Maybe String
  layoutMod = when (hasLayout cf) $ Just (layoutFileM opts)

-- | Generate AST bindings for Agda.
--
cf2AgdaAST
  :: String  -- ^ Current time.
  -> String  -- ^ Module name.
  -> String  -- ^ Haskell Abs module name.
  -> String  -- ^ Haskell Print module name.
  -> CF      -- ^ Grammar.
  -> Doc
cf2AgdaAST time mod amod pmod cf = vsep $
  [ preamble time "abstract syntax data types"
  , hsep [ "module", text mod, "where" ]
  , imports YesImportNumeric False
  , if usesString then hsep [ "String", equals, listT, charT ] else empty
  , importPragmas [amod, unwords [ pmod, "(printTree)" ]]
  , vsep $ map prToken tcats
  , absyn NamedArg dats
  -- , allTokenCats printToken tcats  -- seem to be included in printerCats
  , printers printerCats
  , empty -- Make sure we terminate the file with a new line.
  ]
  where
  -- The grammar categories (excluding list, coerce, and token categories):
  dats :: [Data]
  dats = cf2data cf
         -- getAbstractSyntax also includes list categories, which isn't what we need
  -- The user-defined token categories (including Ident).
  tcats :: [TokenCat]
  tcats = specialCats cf
  -- Bind printers for the following categories (involves lists and literals).
  printerCats :: [Cat]
  printerCats = map fst (getAbstractSyntax cf) ++ map TokenCat (cfgLiterals cf)
  usesString = "String" `elem` cfgLiterals cf


-- | Generate parser bindings for Agda.
--
cf2AgdaParser
  :: String  -- ^ Current time.
  -> String  -- ^ Module name.
  -> String  -- ^ Agda AST module name.
  -> String  -- ^ Haskell Abs module name.
  -> String  -- ^ Haskell ErrM module name.
  -> String  -- ^ Haskell Par module name.
  -> Maybe String
             -- ^ Does the grammar use layout?  If yes, Haskell Layout module name.
  -> [Cat]   -- ^ Bind parsers for these non-terminals.
  -> Doc
cf2AgdaParser time mod astmod amod emod pmod layoutMod cats = vsep $
  [ preamble time "parsers"
  , hsep [ "module", text mod, "where" ]
  , imports NoImportNumeric (isJust layoutMod)
  , importCats astmod (List.nub cs)
  , importPragmas $ [amod, emod, pmod] ++ maybe [] (\ m -> ["qualified " ++ m]) layoutMod
  , "-- Error monad of BNFC"
  , prErrM
  , "-- Happy parsers"
  , parsers layoutMod cats
  , empty -- Make sure we terminate the file with a new line.
  ]
  where
  cs :: [String]
  cs = mapMaybe baseCat cats
  baseCat :: Cat -> Maybe String
  baseCat = \case
    Cat s         -> Just s
    CoercCat s _  -> Just s
    TokenCat "Char" -> Nothing
    TokenCat s    -> Just s
    ListCat c     -> baseCat c
    InternalCat{} -> Nothing

-- We prefix the Agda types with "#" to not conflict with user-provided nonterminals.
arrow, charT, intT, listT, stringT, stringFromListT :: Doc
arrow = "→"
charT           = "Char"     -- This is the BNFC name for token type Char!
intT            = "Integer"  -- This is the BNFC name for token type Integer!
doubleT         = "Double"   -- This is the BNFC name for token type Double!
boolT           = "#Bool"
listT           = "#List"
stringT         = "#String"
stringFromListT = "#stringFromList"

-- | Preamble: introductory comments.

preamble
  :: String  -- ^ Time stamp.
  -> String  -- ^ Brief characterization of file content.
  -> Doc
preamble _time what = vcat $
  [ hcat [ "-- Agda bindings for the Haskell ", text what, "." ]
  , hcat [ "-- Generated by BNFC." ]
  -- -- Time stamp does not work well with BNFC's mkfile logic.
  -- , hcat [ "-- Generated by BNFC at "         , text time, "." ]
  ]

-- | Import statements.

imports
  :: ImportNumeric -- ^ Import also numeric types?
  -> Bool          -- ^ If have layout, import booleans.
  -> Doc
imports numeric layout = vcat . map prettyImport . concat $
  [ when layout
    [ ("Agda.Builtin.Bool",   [("Bool", boolT)]) ]
  , [ ("Agda.Builtin.Char",   [("Char", charT)]) ]
  , when (numeric == YesImportNumeric) importNumeric
  , [ ("Agda.Builtin.List",   [("List", listT)])
    , ("Agda.Builtin.String", [("String", stringT), ("primStringFromList", stringFromListT) ])
    ]
  ]
  where
  importNumeric :: [(String, [(String, Doc)])]
  importNumeric =
    [ ("Agda.Builtin.Float public", [("Float", doubleT)])
    , ("Agda.Builtin.Int   public", [("Int", intT)])
    ]
  prettyImport :: (String, [(String, Doc)]) -> Doc
  prettyImport (m, ren) = prettyList 2 pre lparen rparen semi $
    map (\ (x, d) -> hsep [text x, "to", d ]) ren
    where
    pre = hsep [ "open", "import", text m, "using", "()", "renaming" ]

-- | Import Agda AST.
--
importCats
  :: String    -- ^ Module for Agda AST.
  -> [String]  -- ^ Agda data types to import.
  -> Doc
importCats m cs = prettyList 2 pre lparen rparen semi $ map text cs
  where
  pre = hsep [ "open", "import", text m, "using" ]

-- | Import pragmas.
--
-- >>> importPragmas ["Foo.Abs", "Foo.Print (printTree)", "qualified Foo.Layout"]
-- {-# FOREIGN GHC import qualified Data.Text #-}
-- {-# FOREIGN GHC import Foo.Abs #-}
-- {-# FOREIGN GHC import Foo.Print (printTree) #-}
-- {-# FOREIGN GHC import qualified Foo.Layout #-}
--
importPragmas
  :: [String]  -- ^ Haskell modules to import.
  -> Doc
importPragmas mods = vcat $ map imp $ [ "qualified Data.Text" ] ++ mods
  where
  imp s = hsep [ "{-#", "FOREIGN", "GHC", "import", text s, "#-}" ]

-- * Bindings for the AST.

-- | Pretty-print types for token types similar to @Ident@.

prToken :: String -> Doc
prToken t =
  prettyData UnnamedArg t [(agdaLower t, [ListCat (Cat "Char")])]
  $++$
  pragmaData t [(t, [])]

-- | Pretty-print abstract syntax definition in Agda syntax.
--
--   We print this as one big mutual block rather than doing a
--   strongly-connected component analysis and topological
--   sort by dependency order.
--
absyn :: ConstructorStyle -> [Data] -> Doc
absyn _style [] = empty
absyn style  ds = vsep . ("mutual" :) . concatMap (map (nest 2) . prData style) $ ds

-- | Pretty-print Agda data types and pragmas for AST.
--
-- >>> vsep $ prData UnnamedArg (Cat "Nat", [ ("Zero", []), ("Suc", [Cat "Nat"]) ])
-- data Nat : Set where
--   zero : Nat
--   suc : Nat → Nat
-- <BLANKLINE>
-- {-# COMPILE GHC Nat = data Nat
--   ( Zero
--   | Suc
--   ) #-}
--
-- >>> vsep $ prData UnnamedArg (Cat "C", [ ("C1", []), ("C2", [Cat "C"]) ])
-- data C : Set where
--   c1 : C
--   c2 : C → C
-- <BLANKLINE>
-- {-# COMPILE GHC C = data C
--   ( C1
--   | C2
--   ) #-}
--
-- We return a list of 'Doc' rather than a single 'Doc' since want
-- to intersperse empty lines and indent it later.
-- If we intersperse the empty line(s) here to get a single 'Doc',
-- we will produce whitespace lines after applying 'nest'.
-- This is a bit of a design problem of the pretty print library:
-- there is no native concept of a blank line; @text ""@ is a bad hack.
--
prData :: ConstructorStyle -> Data -> [Doc]
prData style (Cat d, cs) = prData' style d cs
prData _     (c    , _ ) = error $ "prData: unexpected category " ++ show c

-- | Pretty-print Agda data types and pragmas.
--
-- >>> vsep $ prData' UnnamedArg "Err A" [ ("Ok", [Cat "A"]), ("Bad", [ListCat $ Cat "Char"]) ]
-- data Err A : Set where
--   ok : A → Err A
--   bad : #List Char → Err A
-- <BLANKLINE>
-- {-# COMPILE GHC Err = data Err
--   ( Ok
--   | Bad
--   ) #-}
--
prData' :: ConstructorStyle -> String -> [(Fun, [Cat])] -> [Doc]
prData' style d cs = [ prettyData style d cs , pragmaData (head $ words d) cs ]

-- | Pretty-print Agda binding for the BNFC Err monad.
--
-- Note: we use "Err" here since a category "Err" would also conflict
-- with BNFC's error monad in the Haskell backend.
prErrM :: Doc
prErrM = vsep $ prData' UnnamedArg "Err A"
  [ ("Ok" , [Cat "A"])
  , ("Bad", [ListCat $ Cat "Char"])
  ]

-- | Pretty-print AST definition in Agda syntax.
--
-- >>> prettyData UnnamedArg "Nat" [ ("zero", []), ("suc", [Cat "Nat"]) ]
-- data Nat : Set where
--   zero : Nat
--   suc : Nat → Nat
--
-- >>> prettyData UnnamedArg "C" [ ("C1", []), ("C2", [Cat "C"]) ]
-- data C : Set where
--   c1 : C
--   c2 : C → C
--
-- >>> :{
--   prettyData UnnamedArg "Stm"
--     [ ("block", [ListCat $ Cat "Stm"])
--     , ("while", [Cat "Exp", Cat "Stm"])
--     ]
-- :}
-- data Stm : Set where
--   block : #List Stm → Stm
--   while : Exp → Stm → Stm
--
-- >>> :{
--   prettyData NamedArg "Stm"
--     [ ("block", [ListCat $ Cat "Stm"])
--     , ("if", [Cat "Exp", Cat "Stm", Cat "Stm"])
--     ]
-- :}
-- data Stm : Set where
--   block : (ss : #List Stm) → Stm
--   if : (e : Exp) (s₁ s₂ : Stm) → Stm
--
prettyData :: ConstructorStyle -> String -> [(Fun, [Cat])] -> Doc
prettyData style d cs = vcat $
  [ hsep [ "data", text d, colon, "Set", "where" ] ] ++
  map (nest 2 . prettyConstructor style d) cs

-- | Generate pragmas to bind Haskell AST to Agda.
--
-- >>> pragmaData "Empty" []
-- {-# COMPILE GHC Empty = data Empty () #-}
--
-- >>> pragmaData "Nat" [ ("zero", []), ("suc", [Cat "Nat"]) ]
-- {-# COMPILE GHC Nat = data Nat
--   ( zero
--   | suc
--   ) #-}
--
pragmaData :: String -> [(Fun, [Cat])] -> Doc
pragmaData d cs = prettyList 2 pre lparen (rparen <+> "#-}") "|" $
  map (prettyFun . fst) cs
  where
  pre = hsep [ "{-#", "COMPILE", "GHC", text d, equals, "data", text d ]

-- | Pretty-print since rule as Agda constructor declaration.
--
-- >>> prettyConstructor UnnamedArg "D" ("c", [Cat "A", Cat "B", Cat "C"])
-- c : A → B → C → D
-- >>> prettyConstructor undefined  "D" ("c1", [])
-- c1 : D
-- >>> prettyConstructor NamedArg "Stm" ("SIf", map Cat ["Exp", "Stm", "Stm"])
-- sIf : (e : Exp) (s₁ s₂ : Stm) → Stm
--
prettyConstructor :: ConstructorStyle -> String -> (Fun,[Cat]) -> Doc
prettyConstructor _style d (c, []) = hsep $
  [ prettyCon c
  , colon
  , text d
  ]
prettyConstructor style d (c, as) = hsep $
  [ prettyCon c
  , colon
  , prettyConstructorArgs style as
  , arrow
  , text d
  ]

-- | Print the constructor argument telescope.
--
-- >>> prettyConstructorArgs UnnamedArg [Cat "A", Cat "B", Cat "C"]
-- A → B → C
--
-- >>> prettyConstructorArgs NamedArg (map Cat ["Exp", "Stm", "Stm"])
-- (e : Exp) (s₁ s₂ : Stm)
--
prettyConstructorArgs :: ConstructorStyle -> [Cat] -> Doc
prettyConstructorArgs style as =
  case style of
    UnnamedArg -> hsep $ List.intersperse arrow ts
    NamedArg   -> hsep $ map (\ (x :| xs, t) -> parens (hsep [x, hsep xs, colon, t])) tel
  where
  ts  = map prettyCat as
  ns  = map (text . subscript) $ numberUniquely $ map nameSuggestion as
  tel = aggregateOn (render . snd) $ zip ns ts
  subscript (m, s) = maybe s (\ i -> s ++ [chr (ord '₀' + i)]) m
  -- Aggregate consecutive arguments of the same type.
  aggregateOn :: Eq c => ((a,b) -> c) -> [(a,b)] -> [(NEList a,b)]
  aggregateOn f
    = map (\ p -> (NEList.map fst p, snd (NEList.head p)))
    . NEList.groupBy ((==) `on` f)
    -- . NEList.groupWith f -- Too recent, fails stack-7.8 install

-- | Suggest the name of a bound variable of the given category.
--
-- >>> map nameSuggestion [ ListCat (Cat "Stm"), TokenCat "Var", Cat "Exp" ]
-- ["ss","x","e"]
--
nameSuggestion :: Cat -> String
nameSuggestion = \case
  ListCat c     -> nameSuggestion c ++ "s"
  CoercCat d _  -> nameFor d
  Cat d         -> nameFor d
  TokenCat{}    -> "x"
  InternalCat{} -> error "impossible: Backend.Agda.nameSuggestion: Cat cannot be InternalCat"

-- | Suggest the name of a bound variable of the given base category.
--
-- >>> map nameFor ["Stm","ABC","#String"]
-- ["s","a","s"]
--
nameFor :: String -> String
nameFor d = [ toLower $ head $ dropWhile (== '#') d ]

-- | Number duplicate elements in a list consecutively, starting with 1.
--
-- >>> numberUniquely ["a", "b", "a", "a", "c", "b"]
-- [(Just 1,"a"),(Just 1,"b"),(Just 2,"a"),(Just 3,"a"),(Nothing,"c"),(Just 2,"b")]
--
numberUniquely :: forall a. Ord a => [a] -> [(Maybe Int, a)]
numberUniquely as = mapM step as `evalState` Map.empty
  where
  -- First pass: determine frequency of each element.
  counts :: Frequency a
  counts = foldl (flip incr) Map.empty as
  -- Second pass: consecutively number elements with frequency > 1.
  step :: a -> State (Frequency a) (Maybe Int, a)
  step a = do
    -- If the element has a unique occurrence, we do not need to number it.
    let n = Map.findWithDefault (error "numberUniquelyWith") a counts
    if n == 1 then return (Nothing, a) else do
      -- Otherwise, increase the counter for that element and number it
      -- with the new value.
      modify $ incr a
      (,a) . Map.lookup a <$> get

-- | A frequency map.
--
--   NB: this type synonym should be local to 'numberUniquely', but
--   Haskell lacks local type synonyms.
--   https://gitlab.haskell.org/ghc/ghc/issues/4020
type Frequency a = Map a Int

-- | Increase the frequency of the given key.
incr :: Ord a => a -> Frequency a -> Frequency a
incr = Map.alter $ maybe (Just 1) (Just . succ)

-- * Generate bindings for the pretty printers

-- | Generate Agda code to print tokens.
--
-- >>> printToken "Ident"
-- printIdent : Ident → #String
-- printIdent (ident s) = #stringFromList s
--
printToken :: String -> Doc
printToken t = vcat
  [ hsep [ f, colon, text t, arrow, stringT ]
  , hsep [ f, lparen <> c <+> "s" <> rparen, equals, stringFromListT, "s" ]
  ]
  where
  f = text $ "print" ++ t
  c = text $ agdaLower t

-- | Generate Agda bindings to printers for AST.
--
-- >>> printers $ map Cat [ "Exp", "Stm" ]
-- -- Binding the pretty printers.
-- <BLANKLINE>
-- postulate
--   printExp : Exp → #String
--   printStm : Stm → #String
-- <BLANKLINE>
-- {-# COMPILE GHC printExp = \ e -> Data.Text.pack (printTree (e :: Exp)) #-}
-- {-# COMPILE GHC printStm = \ s -> Data.Text.pack (printTree (s :: Stm)) #-}
--
printers :: [Cat] -> Doc
printers []   = empty
printers cats =
  "-- Binding the pretty printers."
  $++$
  vcat ("postulate" : map (nest 2 . prettyTySig) cats)
  $++$
  vcat (map pragmaBind cats)
  where
  prettyTySig c = hsep [ agdaPrinterName c, colon, prettyCat c, arrow, stringT ]
  pragmaBind  c = hsep
    [ "{-#", "COMPILE", "GHC", agdaPrinterName c, equals, "\\", y, "->"
    , "Data.Text.pack", parens ("printTree" <+> parens (y <+> "::" <+> t)), "#-}"
    ]
    where
    y = text $ nameSuggestion c
    t = text $ show $ normCat c  -- Removes CoercCat.

-- | Bind happy parsers.
--
-- >>> parsers Nothing [ListCat (CoercCat "Exp" 2)]
-- postulate
--   parseListExp2 : #String → Err (#List Exp)
-- <BLANKLINE>
-- {-# COMPILE GHC parseListExp2 = pListExp2 . myLexer . Data.Text.unpack #-}
--
parsers
  :: Maybe String  -- ^ Grammar uses layout?  If yes, Haskell layout module name.
  -> [Cat]         -- ^ Bind parsers for these non-terminals.
  -> Doc
parsers layoutMod cats =
  vcat ("postulate" : map (nest 2 . prettyTySig) cats)
  $++$
  vcat (map pragmaBind cats)
  where
  -- When grammar uses layout, we parametrize the parser by a boolean @tl@
  -- that indicates whether top layout should be used for this parser.
  -- Also, we add @resolveLayout tl@ to the pipeline after lexing.
  prettyTySig :: Cat -> Doc
  prettyTySig c = hsep . concat $
   [ [ agdaParserName c, colon ]
   , when layout [ boolT, arrow ]
   , [ stringT, arrow, "Err", prettyCatParens c ]
   ]
  pragmaBind :: Cat -> Doc
  pragmaBind c = hsep . concat $
    [ [ "{-#", "COMPILE", "GHC", agdaParserName c, equals ]
    , when layout [ "\\", "tl", "->" ]
    , [ parserName c, "." ]
    , when layout [ hcat [ text lmod, ".", "resolveLayout" ], "tl", "." ]
    , [ "myLexer", ".", "Data.Text.unpack", "#-}" ]
    ]
  layout :: Bool
  layout = isJust layoutMod
  lmod :: String
  lmod = fromJust layoutMod

-- * Auxiliary functions

-- | Concatenate documents created from token categories,
--   separated by blank lines.
--
-- >>> allTokenCats text ["T", "U"]
-- T
-- <BLANKLINE>
-- U
allTokenCats :: (TokenCat -> Doc) -> [TokenCat] -> Doc
allTokenCats f = vsep . map f

-- | Pretty-print a rule name for Haskell.
prettyFun :: Fun -> Doc
prettyFun = text

-- | Pretty-print a rule name for Agda.
prettyCon :: Fun -> Doc
prettyCon = text . agdaLower

-- | Turn identifier to non-capital identifier.
--   Needed, since in Agda a constructor cannot overload a data type
--   with the same name.
--
-- >>> map agdaLower ["SFun","foo","ABC","HelloWorld","module","Type_int","C1"]
-- ["sFun","foo","aBC","helloWorld","module'","type-int","c1"]
--
agdaLower :: String -> String
agdaLower = avoidKeywords . updateHead toLower . replace '_' '-'
  -- WAS: replace '_' '\'' . BNFC.Utils.mkName agdaKeywords BNFC.Utils.MixedCase
  where
  updateHead _f []    = []
  updateHead f (x:xs) = f x : xs
  avoidKeywords s
    | s `Set.member` agdaKeywords = s ++ "\'"
    | otherwise = s

-- | A list of Agda keywords that would clash with generated names.
agdaKeywords :: Set String
agdaKeywords = Set.fromList $ words "abstract codata coinductive constructor data do eta-equality field forall hiding import in inductive infix infixl infixr instance let macro module mutual no-eta-equality open overlap pattern postulate primitive private public quote quoteContext quoteGoal quoteTerm record renaming rewrite Set syntax tactic unquote unquoteDecl unquoteDef using variable where with"

-- | Name of Agda parser binding (mentions precedence).
--
-- >>> agdaParserName $ ListCat $ CoercCat "Exp" 2
-- parseListExp2
--
agdaParserName :: Cat -> Doc
agdaParserName c = text $ "parse" ++ identCat c

-- | Name of Agda printer binding (does not mention precedence).
--
-- >>> agdaPrinterName $ ListCat $ CoercCat "Exp" 2
-- printListExp
--
agdaPrinterName :: Cat -> Doc
agdaPrinterName c = text $ "print" ++ identCat (normCat c)

-- | Pretty-print a category as Agda type.
--   Ignores precedence.
--
-- >>> prettyCat $ ListCat (CoercCat "Exp" 2)
-- #List Exp
--
prettyCat :: Cat -> Doc
prettyCat = \case
  Cat s        -> text s
  TokenCat s   -> text s
  CoercCat s _ -> text s
  ListCat c    -> listT <+> prettyCatParens c
  InternalCat  -> error "prettyCat: unexpected case InternalCat"

-- | Pretty-print category in parentheses, if 'compositeCat'.
prettyCatParens :: Cat -> Doc
prettyCatParens c = parensIf (compositeCat c) (prettyCat c)

-- | Is the Agda type corresponding to 'Cat' composite (or atomic)?
compositeCat :: Cat -> Bool
compositeCat = \case
  ListCat{} -> True
  _         -> False


-- * Agda stub to test parser

-- | Write a simple IO library with fixed contents.

agdaLibContents
  :: String      -- ^ Name of Agda library module.
  -> Doc         -- ^ Contents of Agda library module.
agdaLibContents mod = vcat
  [ "-- Generated by BNFC."
  , "-- Basic I/O library."
  , ""
  , "module" <+> text mod <+> "where"
  , ""
  , "open import Agda.Builtin.IO     public using (IO)"
  , "open import Agda.Builtin.List   public using (List; []; _∷_)"
  , "open import Agda.Builtin.String public using (String)"
  , "  renaming (primStringFromList to stringFromList)"
  , "open import Agda.Builtin.Unit   public using (⊤)"
  , ""
  , "-- I/O monad."
  , ""
  , "postulate"
  , "  return : ∀ {a} {A : Set a} → A → IO A"
  , "  _>>=_  : ∀ {a b} {A : Set a} {B : Set b} → IO A → (A → IO B) → IO B"
  , ""
  , "{-# COMPILE GHC return = \\ _ _ -> return    #-}"
  , "{-# COMPILE GHC _>>=_  = \\ _ _ _ _ -> (>>=) #-}"
  , ""
  , "infixl 1 _>>=_ _>>_"
  , ""
  , "_>>_  : ∀ {b} {B : Set b} → IO ⊤ → IO B → IO B"
  , "_>>_ = λ m m' → m >>= λ _ → m'"
  , ""
  , "-- Co-bind and functoriality."
  , ""
  , "infixr 1 _=<<_ _<$>_"
  , ""
  , "_=<<_  : ∀ {a b} {A : Set a} {B : Set b} → (A → IO B) → IO A → IO B"
  , "k =<< m = m >>= k"
  , ""
  , "_<$>_  : ∀ {a b} {A : Set a} {B : Set b} → (A → B) → IO A → IO B"
  , "f <$> m = do"
  , "  a ← m"
  , "  return (f a)"
  , ""
  , "-- Binding basic I/O functionality."
  , ""
  , "{-# FOREIGN GHC import qualified Data.Text #-}"
  , "{-# FOREIGN GHC import qualified Data.Text.IO #-}"
  , "{-# FOREIGN GHC import qualified System.Exit #-}"
  , "{-# FOREIGN GHC import qualified System.Environment #-}"
  , "{-# FOREIGN GHC import qualified System.IO #-}"
  , ""
  , "postulate"
  , "  exitFailure    : ∀{a} {A : Set a} → IO A"
  , "  getArgs        : IO (List String)"
  , "  putStrLn       : String → IO ⊤"
  , "  readFiniteFile : String → IO String"
  , ""
  , "{-# COMPILE GHC exitFailure    = \\ _ _ -> System.Exit.exitFailure #-}"
  , "{-# COMPILE GHC getArgs        = fmap (map Data.Text.pack) System.Environment.getArgs #-}"
  , "{-# COMPILE GHC putStrLn       = System.IO.putStrLn . Data.Text.unpack #-}"
  , "{-# COMPILE GHC readFiniteFile = Data.Text.IO.readFile . Data.Text.unpack #-}"
  ]

agdaMainContents
  :: String      -- ^ Name of Agda main module.
  -> String      -- ^ Name of Agda library module.
  -> String      -- ^ Name of Agda AST module.
  -> String      -- ^ Name of Agda parser module.
  -> Bool        -- ^ Is the grammar using layout?
  -> Cat         -- ^ Category to parse.
  -> Doc         -- ^ Contents of Agda main module.
agdaMainContents mod lmod amod pmod layout c = vcat
  [ "-- Test for Agda binding of parser.  Requires Agda >= 2.5.4."
  , "-- Generated by BNFC."
  , ""
  , "module" <+> text mod <+> "where"
  , when layout "\nopen import Agda.Builtin.Bool using (true)"
  , "open import" <+> text lmod
  , "open import" <+> text amod <+> "using" <+> parens (printer)
  , "open import" <+> text pmod <+> "using" <+> parens ("Err;" <+> parser)
  , ""
  , "main : IO ⊤"
  , "main = do"
  , "  file ∷ [] ← getArgs where"
  , "    _ → do"
  , "      putStrLn \"usage: Main <SourceFile>\""
  , "      exitFailure"
  , "  Err.ok result ←" <+> parseFun <+> "<$> readFiniteFile file where"
  , "    Err.bad msg → do"
  , "      putStrLn \"PARSE FAILED\\n\""
  , "      putStrLn (stringFromList msg)"
  , "      exitFailure"
  , "  putStrLn \"PARSE SUCCESSFUL\\n\""
  , "  putStrLn" <+> parens (printer <+> "result")
  ]
  where
  printer  = agdaPrinterName c
  parser   = agdaParserName c
  parseFun = hsep . concat $ [ [parser], when layout ["true"] ]
    -- Permit use of top-level layout, if any.
