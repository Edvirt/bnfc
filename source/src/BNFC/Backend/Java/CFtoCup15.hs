{-
    BNF Converter: Java 1.5 Cup Generator
    Copyright (C) 2004  Author:  Markus Forsberg, Michael Pellauer,
                                 Bjorn Bringert

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, 51 Franklin Street, Fifth Floor, Boston, MA 02110-1335, USA
-}

{-
   **************************************************************
    BNF Converter Module

    Description   : This module generates the CUP input file. It
                    follows the same basic structure of CFtoHappy.

    Author        : Michael Pellauer (pellauer@cs.chalmers.se),
                    Bjorn Bringert (bringert@cs.chalmers.se)

    License       : GPL (GNU General Public License)

    Created       : 26 April, 2003

    Modified      : 5 Aug, 2004


   **************************************************************
-}
module BNFC.Backend.Java.CFtoCup15 ( cf2Cup ) where

import BNFC.CF
import Data.List
import BNFC.Backend.Common.NamedVariables
import BNFC.Options (RecordPositions(..))
import BNFC.Utils ( (+++) )
import BNFC.TypeChecker  -- We need to (re-)typecheck to figure out list instances in
                    -- defined rules.
import ErrM

import Data.Char

type Rules   = [(NonTerminal,[(Pattern,Action)])]
type Pattern = String
type Action  = String
type MetaVar = String

--The environment comes from the CFtoJLex
cf2Cup :: String -> String -> CF -> RecordPositions -> SymEnv -> String
cf2Cup packageBase packageAbsyn cf rp env = unlines
    [ header
    , declarations packageAbsyn (allCats cf)
    , tokens env
    , specialToks cf
    , specialRules cf
    , prEntryPoint cf
    , prRules (rulesForCup packageAbsyn cf rp env)
    ]
  where
    header :: String
    header = unlines
      [ "// -*- Java -*- This Cup file was machine-generated by BNFC"
      , "package" +++ packageBase ++ ";"
      , ""
      , "action code {:"
      , "public java_cup.runtime.ComplexSymbolFactory.Location getLeftLocation("
      , "    java_cup.runtime.ComplexSymbolFactory.Location ... locations) {"
      , "  for (java_cup.runtime.ComplexSymbolFactory.Location l : locations) {"
      , "    if (l != null) {"
      , "      return l;"
      , "    }"
      , "  }"
      , "  return null;"
      , "}"
      , ":}"
      , "parser code {:"
      , parseMethod packageAbsyn (firstEntry cf)
      , "public <B,A extends java.util.LinkedList<? super B>> "
        ++ "A cons_(B x, A xs) { xs.addFirst(x); return xs; }"
      , definedRules packageAbsyn cf
      , "public void syntax_error(java_cup.runtime.Symbol cur_token)"
      , "{"
      , "  report_error(\"Syntax Error, trying to recover and continue"
        ++ " parse...\", cur_token);"
      , "}"
      , ""
      , "public void unrecovered_syntax_error(java_cup.runtime.Symbol "
        ++ "cur_token) throws java.lang.Exception"
      , "{"
      , "  throw new Exception(\"Unrecoverable Syntax Error\");"
      , "}"
      , ""
      , ":}"
      ]

definedRules :: String -> CF -> String
definedRules packageAbsyn cf =
    unlines [ rule f xs e | FunDef f xs e <- cfgPragmas cf ]
  where
    ctx = buildContext cf

    list = LC (\ t -> "List" ++ unBase t) (const "cons")
      where
         unBase (ListT t) = unBase t
         unBase (BaseT x) = show $ normCat $ strToCat x

    rule f xs e =
        case checkDefinition' list ctx f xs e of
            Bad err          ->
                error $ "Panic! This should have been caught already:\n"
                    ++ err
            Ok (args,(e',t)) -> unlines
                [ "public " ++ javaType t ++ " " ++ f ++ "_ (" ++
                    intercalate ", " (map javaArg args) ++ ") {"
                , "  return " ++ javaExp e' ++ ";"
                , "}"
                ]
     where

       javaType :: Base -> String
       javaType (ListT (BaseT x)) = packageAbsyn ++ ".List"
                                   ++ show (normCat $ strToCat x)
       javaType (ListT t)         = javaType t
       javaType (BaseT x)
           | isToken x ctx = "String"
           | otherwise     = packageAbsyn ++ "."
                           ++ show (normCat $ strToCat x)

       javaArg :: (String, Base) -> String
       javaArg (x,t) = javaType t ++ " " ++ x ++ "_"

       javaExp :: Exp -> String
       javaExp (App "null" []) = "null"
       javaExp (App x [])
           | x `elem` xs       = x ++ "_"      -- argument
       javaExp (App t [e])
           | isToken t ctx     = call "new String" [e]
       javaExp (App x es)
           | isUpper (head x)  = call ("new " ++ packageAbsyn ++ "." ++ x) es
           | otherwise         = call (x ++ "_") es
       javaExp (LitInt n)      = "new Integer(" ++ show n ++ ")"
       javaExp (LitDouble x)   = "new Double(" ++ show x ++ ")"
       javaExp (LitChar c)     = "new Character(" ++ show c ++ ")"
       javaExp (LitString s)   = "new String(" ++ show s ++ ")"

       call x es = x ++ "(" ++ intercalate ", " (map javaExp es) ++ ")"


-- peteg: FIXME JavaCUP can only cope with one entry point AFAIK.
prEntryPoint :: CF -> String
prEntryPoint cf = unlines ["", "start with " ++ identCat (firstEntry cf) ++ ";", ""]
--                  [ep]  -> unlines ["", "start with " ++ ep ++ ";", ""]
--                  eps   -> error $ "FIXME multiple entry points." ++ show eps

--This generates a parser method for each entry point.
parseMethod :: String -> Cat -> String
parseMethod packageAbsyn cat = unlines
             [ "  public" +++ packageAbsyn ++ "." ++ dat +++ "p" ++ cat' ++ "()"
                 ++ " throws Exception"
             , "  {"
             , "    java_cup.runtime.Symbol res = parse();"
             , "    return (" ++ packageAbsyn ++ "." ++ dat ++ ") res.value;"
             , "  }"
             ]
    where
    dat  = identCat (normCat cat)
    cat' = identCat cat

--non-terminal types
declarations :: String -> [Cat] -> String
declarations packageAbsyn ns = unlines (map (typeNT packageAbsyn) ns)
 where
   typeNT _nm nt = "nonterminal" +++ packageAbsyn ++ "."
                    ++ identCat (normCat nt) +++ identCat nt ++ ";"

--terminal types
tokens :: SymEnv -> String
tokens ts = unlines (map declTok ts)
 where
  declTok (s,r) = "terminal" +++ r ++ ";    //   " ++ s

specialToks :: CF -> String
specialToks cf = unlines
  [ ifC catString  "terminal String _STRING_;"
  , ifC catChar    "terminal Character _CHAR_;"
  , ifC catInteger "terminal Integer _INTEGER_;"
  , ifC catDouble  "terminal Double _DOUBLE_;"
  , ifC catIdent   "terminal String _IDENT_;"
  ]
   where
    ifC cat s = if isUsedCat cf (TokenCat cat) then s else ""

specialRules:: CF -> String
specialRules cf =
    unlines ["terminal String " ++ name ++ ";" | name <- tokenNames cf]

--The following functions are a (relatively) straightforward translation
--of the ones in CFtoHappy.hs
rulesForCup :: String -> CF -> RecordPositions -> SymEnv -> Rules
rulesForCup packageAbsyn cf rp env = map mkOne $ ruleGroups cf where
  mkOne (cat,rules) = constructRule packageAbsyn cf rp env rules cat

-- | For every non-terminal, we construct a set of rules. A rule is a sequence of
-- terminals and non-terminals, and an action to be performed.
constructRule :: String -> CF -> RecordPositions -> SymEnv -> [Rule] -> NonTerminal
    -> (NonTerminal,[(Pattern,Action)])
constructRule packageAbsyn cf rp env rules nt =
    (nt, [ (p, generateAction packageAbsyn nt (funRule r) (revM b m) b rp)
          | r0 <- rules,
          let (b,r) = if isConsFun (funRule r0) && elem (valCat r0) revs
                          then (True, revSepListRule r0)
                          else (False, r0)
              (p,m) = generatePatterns env r])
 where
   revM False = id
   revM True  = reverse
   revs       = cfgReversibleCats cf

-- Generates a string containing the semantic action.
generateAction :: String -> NonTerminal -> Fun -> [MetaVar]
               -> Bool   -- ^ Whether the list should be reversed or not.
                         --   Only used if this is a list rule.
               -> RecordPositions   -- ^ Record line and column info.
               -> Action
generateAction packageAbsyn nt f ms rev rp
    | isNilFun f      = "RESULT = new " ++ c ++ "();"
    | isOneFun f      = "RESULT = new " ++ c ++ "(); RESULT.addLast("
                           ++ p_1 ++ ");"
    | isConsFun f     = "RESULT = " ++ p_2 ++ "; "
                           ++ p_2 ++ "." ++ add ++ "(" ++ p_1 ++ ");"
    | isCoercion f    = "RESULT = " ++ p_1 ++ ";"
    | isDefinedRule f = "RESULT = parser." ++ f ++ "_"
                        ++ "(" ++ intercalate "," ms ++ ");"
    | otherwise       = "RESULT = new " ++ c
                  ++ "(" ++ intercalate "," ms ++ ");" ++ lineInfo
   where
     c   = packageAbsyn ++ "." ++
           if isNilFun f || isOneFun f || isConsFun f
             then identCat (normCat nt) else f
     p_1 = ms !! 0
     p_2 = ms !! 1
     add = if rev then "addLast" else "addFirst"
     lineInfo =
        if rp == RecordPositions
          then case ms of
            [] -> "\n((" ++ c ++ ")RESULT).line_num = -1;" ++
                  "\n((" ++ c ++ ")RESULT).col_num = -1;" ++
                  "\n((" ++ c ++ ")RESULT).offset = -1;"
            _  -> "\njava_cup.runtime.ComplexSymbolFactory.Location leftLoc = getLeftLocation(" ++
                  intercalate "," (map (++"xleft") ms) ++ ");" ++
                  "\nif (leftLoc != null) {" ++
                  "\n  ((" ++ c ++ ")RESULT).line_num = leftLoc.getLine();" ++
                  "\n  ((" ++ c ++ ")RESULT).col_num = leftLoc.getColumn();" ++
                  "\n  ((" ++ c ++ ")RESULT).offset = leftLoc.getOffset();" ++
                  "\n} else {" ++
                  "\n  ((" ++ c ++ ")RESULT).line_num = -1;" ++
                  "\n  ((" ++ c ++ ")RESULT).col_num = -1;" ++
                  "\n  ((" ++ c ++ ")RESULT).offset = -1;" ++
                  "\n}"
          else ""


-- | Generate patterns and a set of metavariables indicating
-- where in the pattern the non-terminal.
--
-- >>> generatePatterns [] (Rule "myfun" (Cat "A") [])
-- (" /* empty */ ",[])
--
-- >>> generatePatterns [("def", "_SYMB_1")] (Rule "myfun" (Cat "A") [Right "def", Left (Cat "B")])
-- ("_SYMB_1:p_1 B:p_2 ",["p_2"])

generatePatterns :: SymEnv -> Rule -> (Pattern,[MetaVar])
generatePatterns env r = case rhsRule r of
    []  -> (" /* empty */ ", [])
    its -> (mkIt 1 its, metas its)
 where
    mkIt _ [] = []
    mkIt n (i:is) =
      case i of
        Left c -> c' ++ ":p_" ++ show (n :: Int) +++ mkIt (n+1) is
          where
              c' = case c of
                  TokenCat "Ident"   -> "_IDENT_"
                  TokenCat "Integer" -> "_INTEGER_"
                  TokenCat "Char"    -> "_CHAR_"
                  TokenCat "Double"  -> "_DOUBLE_"
                  TokenCat "String"  -> "_STRING_"
                  _ -> identCat c
        Right s -> case lookup s env of
            Just x  -> (x ++ ":p_" ++ show (n :: Int)) +++ mkIt (n+1) is
            Nothing -> mkIt n is
    metas its = ["p_" ++ show i | (i,Left _) <- zip [1 :: Int ..] its]

-- We have now constructed the patterns and actions,
-- so the only thing left is to merge them into one string.
prRules :: Rules -> String
prRules []                    = []
prRules ((_ , []      ) : rs) = prRules rs --internal rule
prRules ((nt, (p,a):ls) : rs) =
    unwords [ nt', "::=", p, "{:", a, ":}", '\n' : pr ls ] ++ ";\n" ++ prRules rs
  where
    nt' = identCat nt
    pr []           = []
    pr ((p,a):ls)   = unlines [ unwords [ "  |", p, "{:", a , ":}" ] ] ++ pr ls
