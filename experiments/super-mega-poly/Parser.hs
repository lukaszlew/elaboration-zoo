
module Parser (parseString, parseStdin) where

import Control.Applicative hiding (many, some)
import Control.Monad
import Data.Char
import Data.Foldable
import Data.Void
import System.Exit
import Text.Megaparsec

import qualified Text.Megaparsec.Char       as C
import qualified Text.Megaparsec.Char.Lexer as L

import Common
import Presyntax

--------------------------------------------------------------------------------

type Parser = Parsec Void String

ws :: Parser ()
ws = L.space C.space1 (L.skipLineComment "--") (L.skipBlockComment "{-" "-}")

withPos :: Parser Tm -> Parser Tm
withPos p = SrcPos <$> getSourcePos <*> p

lexeme     = L.lexeme ws
symbol s   = lexeme (C.string s)
char c     = lexeme (C.char c)
parens p   = char '(' *> p <* char ')'
braces p   = char '{' *> p <* char '}'
pArrow     = symbol "→" <|> symbol "->"
pBind      = pIdent <|> symbol "_"

keyword :: String -> Bool
keyword x = x == "let" || x == "λ" || x == "U" || x == "exists"

pIdent :: Parser Name
pIdent = try $ do
  x <- takeWhile1P Nothing isAlphaNum
  guard (not (keyword x))
  x <$ ws

pKeyword :: String -> Parser ()
pKeyword kw = do
  C.string kw
  (takeWhile1P Nothing isAlphaNum *> empty) <|> ws

pPair :: Parser Tm
pPair = do
  char '{'
  ts <- sepBy1 pTm (char ',')
  char '}'
  pure $ foldr1 Pair ts

pAtom :: Parser Tm
pAtom  =
      withPos (    (Var <$> pIdent)
               <|> (U <$ char 'U')
               <|> (Hole <$ char '_')
               <|> pPair)
  <|> parens pTm

pProj :: Parser Tm
pProj = do
  t <- pAtom
  let go t = (symbol ".1" *> go (Proj1 t))
         <|> (symbol ".2" *> go (Proj2 t))
         <|> pure t
  go t

pArg :: Parser (Either Name Icit, Tm)
pArg =  (try $ braces $ do {x <- pIdent; char '='; t <- pTm; pure (Left x, t)})
    <|> (do
          char '{'
          ts <- sepBy1 pTm (char ',')
          let res = case ts of
                [t] -> (Right Impl, t)
                ts  -> (Right Expl, foldr1 Pair ts)
          char '}'
          pure res)
    <|> ((Right Expl,) <$> pProj)

pSpine :: Parser Tm
pSpine = do
  h <- pProj
  args <- many pArg
  pure $ foldl' (\t (i, u) -> App t u i) h args

pLamBinder :: Parser (Name, Either Name Icit)
pLamBinder =
      ((,Right Expl) <$> pBind)
  <|> try ((,Right Impl) <$> braces pBind)
  <|> braces (do {x <- pIdent; char '='; y <- pBind; pure (y, Left x)})

pLam :: Parser Tm
pLam = do
  char 'λ' <|> char '\\'
  xs <- some pLamBinder
  char '.'
  t <- pTm
  pure $ foldr (uncurry Lam) t xs

pPiBinder :: Parser ([Name], Tm, Icit)
pPiBinder =
      braces ((,,Impl) <$> some pBind
                       <*> ((char ':' *> pTm) <|> pure Hole))
  <|> parens ((,,Expl) <$> some pBind
                       <*> (char ':' *> pTm))
pPi :: Parser Tm
pPi = do
  dom <- some pPiBinder
  pArrow
  cod <- pTm
  pure $ foldr (\(xs, a, i) t -> foldr (\x -> Pi x i a) t xs) cod dom

pFunOrSpine :: Parser Tm
pFunOrSpine = do
  sp <- pSpine
  optional pArrow >>= \case
    Nothing -> pure sp
    Just _  -> Pi "_" Expl sp <$> pTm

pLet :: Parser Tm
pLet = do
  pKeyword "let"
  x <- pIdent
  ann <- optional (char ':' *> pTm)
  char '='
  t <- pTm
  symbol ";"
  u <- pTm
  pure $ Let x (maybe Hole id ann) t u

pEx :: Parser Tm
pEx = do
  (() <$ char '∃') <|> (() <$ symbol "exists")
  x <- pIdent
  a <- optional (char ':' *> pTm)
  char '.'
  b <- pTm
  pure $ Ex x a b

pTm :: Parser Tm
pTm = withPos (pLam <|> pLet <|> pEx <|> try pPi <|> pFunOrSpine)

pSrc :: Parser Tm
pSrc = ws *> pTm <* eof

parseString :: String -> IO Tm
parseString src =
  case parse pSrc "(stdin)" src of
    Left e -> do
      putStrLn $ errorBundlePretty e
      exitFailure
    Right t ->
      pure t

parseStdin :: IO (Tm, String)
parseStdin = do
  src <- getContents
  t <- parseString src
  pure (t, src)
