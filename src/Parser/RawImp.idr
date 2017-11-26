module Parser.RawImp

import Core.TT
import Core.RawContext
import TTImp.TTImp

import public Parser.Support
import public Text.Parser
import Data.List.Views

%default covering

-- Forward declare since they're used in the parser
topDecl : Rule (ImpDecl ())
collectDefs : List (ImpDecl ()) -> List (ImpDecl ())

atom : Rule (RawImp ())
atom
    = do x <- constant
         pure (IPrimVal () x)
  <|> do keyword "Type"
         pure (IType ())
  <|> do symbol "_"
         pure (Implicit ())
  <|> do symbol "$"
         x <- unqualifiedName
         pure (IBindVar () x)
  <|> do symbol "?"
         x <- unqualifiedName
         pure (IHole () x)
  <|> do x <- name
         pure (IVar () x)

mutual
  appExpr : Rule (RawImp ())
  appExpr
      = do f <- simpleExpr
           args <- many simpleExpr
           pure (apply f args)

  simpleExpr : Rule (RawImp ())
  simpleExpr
      = do x <- unqualifiedName
           symbol "@"
           commit
           expr <- simpleExpr
           pure (IAs () x expr)
    <|> atom
    <|> binder
    <|> do symbol ".("
           commit
           e <- expr
           symbol ")"
           pure (IMustUnify () e)
    <|> do symbol "(|"
           commit
           alts <- sepBy1 (symbol ",") expr
           symbol "|)"
           pure (IAlternative () True alts)
    <|> do symbol "("
           e <- expr
           symbol ")"
           pure e

  explicitPi : Rule (RawImp ())
  explicitPi
      = do symbol "("
           n <- name
           symbol ":"
           commit
           ty <- expr
           symbol ")"
           symbol "->"
           scope <- typeExpr
           pure (IPi () Explicit (Just n) ty scope)

  autoImplicitPi : Rule (RawImp ())
  autoImplicitPi
      = do symbol "{"
           keyword "auto"
           commit
           n <- name
           symbol ":"
           ty <- expr
           symbol "}"
           symbol "->"
           scope <- typeExpr
           pure (IPi () Implicit (Just n) ty scope)

  implicitPi : Rule (RawImp ())
  implicitPi
      = do symbol "{"
           n <- name
           symbol ":"
           commit
           ty <- expr
           symbol "}"
           symbol "->"
           scope <- typeExpr
           pure (IPi () Implicit (Just n) ty scope)

  lam : Rule (RawImp ())
  lam
      = do symbol "\\"
           n <- name
           ty <- option 
                    (Implicit ())
                    (do symbol ":"
                        expr)
           symbol "=>"
           scope <- typeExpr
           pure (ILam () Explicit n ty scope)

  let_ : Rule (RawImp ())
  let_
      = do keyword "let"
           n <- name
           commit
           ty <- option 
                    (Implicit ())
                    (do symbol ":"
                        expr)
           symbol "="
           val <- expr
           keyword "in"
           scope <- typeExpr
           pure (ILet () n ty val scope)
    <|> do keyword "let"
           symbol "{"
           ds <- some topDecl
           symbol "}"
           keyword "in"
           scope <- typeExpr
           pure (ILocal () (collectDefs ds) scope)

  binder : Rule (RawImp ())
  binder
      = autoImplicitPi
    <|> implicitPi
    <|> explicitPi
    <|> lam
    <|> let_

  typeExpr : Rule (RawImp ())
  typeExpr
      = do arg <- appExpr
           (do symbol "->"
               rest <- sepBy (symbol "->") appExpr
               pure (mkPi arg rest))
             <|> pure arg
    where
      mkPi : RawImp () -> List (RawImp ()) -> RawImp ()
      mkPi arg [] = arg
      mkPi arg (a :: as) = IPi () Explicit Nothing arg (mkPi a as)

  export
  expr : Rule (RawImp ())
  expr = typeExpr

tyDecl : Rule (ImpTy ())
tyDecl
    = do n <- name
         symbol ":"
         ty <- expr
         symbol ";"
         pure (MkImpTy () n ty)

clause : Rule (Name, ImpClause ())
clause
    = do lhs <- expr
         symbol "="
         rhs <- expr
         symbol ";"
         fn <- getFn lhs
         -- Turn lower case names on lhs into IBindVar pattern variables
         -- before returning
         pure (fn, MkImpClause () (mkLCPatVars lhs) rhs)
  where
    getFn : RawImp annot -> EmptyRule Name
    getFn (IVar _ n) = pure n
    getFn (IApp _ f a) = getFn f
    getFn _ = fail "Not a function application" 

dataDecl : Rule (ImpData ())
dataDecl
    = do keyword "data"
         n <- name
         symbol ":"
         ty <- expr
         keyword "where"
         symbol "{"
         cs <- many tyDecl
         symbol "}"
         pure (MkImpData () n ty cs)

implicitsDecl : Rule (List (String, RawImp ()))
implicitsDecl
    = do keyword "implicit"
         commit
         ns <- sepBy1 (symbol ",") impDecl
         symbol ";"
         pure ns
  where
    impDecl : Rule (String, RawImp ())
    impDecl 
        = do x <- unqualifiedName
             ty <- option (Implicit ())
                          (do symbol ":"
                              expr)
             pure (x, ty)

namespaceDecl : Rule (List String)
namespaceDecl
    = do keyword "namespace"
         commit
         ns <- namespace_
         symbol ";"
         pure ns

directive : Rule (ImpDecl ())
directive
    = do exactIdent "logging"
         lvl <- intLit
         symbol ";"
         pure (ILog (cast lvl))

-- Declared at the top
-- topDecl : Rule (ImpDecl ())
topDecl
    = do dat <- dataDecl
         pure (IData () dat)
  <|> do ns <- namespaceDecl
         pure (INamespace () ns)
  <|> do ns <- implicitsDecl
         pure (ImplicitNames () ns)
  <|> do symbol "%"; commit
         directive
  <|> do claim <- tyDecl
         pure (IClaim () claim)
  <|> do nd <- clause
         pure (IDef () (fst nd) [snd nd])

-- All the clauses get parsed as one-clause definitions. Collect any
-- neighbouring clauses with the same function name into one definition.
-- Declared at the top.
-- collectDefs : List (ImpDecl ()) -> List (ImpDecl ())
collectDefs [] = []
collectDefs (IDef annot fn cs :: ds)
    = let (cs', rest) = spanMap (isClause fn) ds in
          IDef annot fn (cs ++ cs') :: assert_total (collectDefs rest)
  where
    spanMap : (a -> Maybe (List b)) -> List a -> (List b, List a)
    spanMap f [] = ([], [])
    spanMap f (x :: xs) = case f x of
                               Nothing => ([], x :: xs)
                               Just y => case spanMap f xs of
                                              (ys, zs) => (y ++ ys, zs)

    isClause : Name -> ImpDecl () -> Maybe (List (ImpClause ()))
    isClause n (IDef annot n' cs) 
        = if n == n' then Just cs else Nothing
    isClause n _ = Nothing
collectDefs (d :: ds)
    = d :: collectDefs ds

export
prog : Rule (List (ImpDecl ()))
prog 
    = do ds <- some topDecl
         pure (collectDefs ds)