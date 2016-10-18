module Combine
  exposing
    ( Parser, InputStream, ParseLocation, ParseContext, ParseResult
    , primitive, rec
    , app, parse, runParser
    , withState, putState, modifyState
    , withLocation, withLine, withColumn, currentLocation, currentSourceLine, currentLine, currentColumn
    , map, mapError
    , andThen, andMap, sequence
    , fail, succeed, string, regex, while, end
    , lookAhead, or, choice, optional, maybe, many, many1, manyTill
    , sepBy, sepBy1, sepEndBy, sepEndBy1, skip, skipMany, skipMany1
    , chainl, chainr, count, between, parens
    , braces, brackets, whitespace
    , (<?>), (>>=), (<$>), (<$), ($>), (<*>), (<*), (*>), (<|>)
    )

{-| This library provides reasonably fast parser combinators.

# Types
@docs Parser, InputStream, ParseLocation, ParseContext, ParseResult

## Constructing Parsers
@docs primitive, rec

## Running a Parser
@docs app, parse, runParser

## Managing state
@docs withState, putState, modifyState, withLocation, withLine, withColumn, currentLocation, currentSourceLine, currentLine, currentColumn

## Transforming Parsers
@docs map, mapError

## Chaining Parsers
@docs andThen, andMap, sequence

## Combinators
@docs fail, succeed, string, regex, while, end, lookAhead, or, choice, optional, maybe, many, many1, manyTill, sepBy, sepBy1, sepEndBy, sepEndBy1, skip, skipMany, skipMany1, chainl, chainr, count, between, parens, braces, brackets, whitespace

## Infix combinators
@docs (<?>), (>>=), (<$>), (<$), ($>), (<*>), (<*), (*>), (<|>)
-}

import Lazy as L
import Regex exposing (Regex(..))
import String


{-| The input stream over which `Parser`s operate.

* `data` is the initial input provided by the user
* `input` is the remainder after running a parse
* `position` is the absolute byte position of the parser after running a parse

 -}
type alias InputStream =
  { data: String
  , input : String
  , position : Int
  }

initStream : String -> InputStream
initStream s = InputStream s s 0


{-| A record representing the current parse location in an InputStream.

* `source` the current line of source code
* `line` the current line number (starting at 1)
* `column` the current column (starting at 1)
-}
type alias ParseLocation =
  { source : String
  , line : Int
  , column : Int
  }


{-| A triple representing the current parser state, the remaining
input stream and the parse result. -}
type alias ParseContext state res =
  (state, InputStream, ParseResult res)


{-| Running a `Parser` results in one of two states:

* `Ok res` when the parser has successfully parsed the input
* `Err messages` when the parser has failed with a list of error messages.
-}
type alias ParseResult res =
  Result (List String) res


type alias ParseFn state res =
  state -> InputStream -> ParseContext state res


{-| The Parser type.

At their core, `Parser`s wrap functions from some `state` and an
`InputStream` to a tuple representing the some new `state`, the
remaining `InputStream` and a `ParseResult res`.
-}
type Parser state res
  = Parser (ParseFn state res)
  | RecursiveParser (L.Lazy (ParseFn state res))


{-| Construct a new primitive Parser.

If you find yourself reaching for this function often consider opening
a [Github issue][issues] with the library to have your custom Parsers
included in the standard distribution.

[issues]: https://github.com/Bogdanp/elm-combine/issues
-}
primitive : (state -> InputStream -> ParseContext state res) -> Parser state res
primitive = Parser


{-| Unwrap a parser so it can be applied to a context. -}
app : Parser state res -> state -> InputStream -> ParseContext state res
app p =
  case p of
    Parser p ->
      p

    RecursiveParser t ->
      L.force t


{-| Parse a string.  See `runParser` if your parser needs to manage
some internal state.

    import Combine.Num exposing (int)

    parse int "123"
    -- Ok 123

    parse int "abc"
    -- Err ["expeccted an integer"]

 -}
parse : Parser () res -> String -> ParseContext () res
parse p = runParser p ()


{-| Parse a string while maintaining some internal state. -}
runParser : Parser state res -> state -> String -> ParseContext state res
runParser p st s = app p st (initStream s)


{-| Defer running a parser until it's actually required.  Use this
function to avoid "bad-recursion" errors.

    type Expression
      = ETerm String
      | EList (List E)

    whitespace : Parser s String
    whitespace = regex "[ \t\r\n]*"

    name : Parser s String
    name = whitespace *> regex "[a-zA-Z]+" <* whitespace

    term : Parser s Expression
    term = ETerm <$> name

    list : Parser s Expression
    list =
      let
        -- helper is itself a function so we avoid the case where the
        -- value `list` tries to apply itself in its definition.
        helper () =
          EList <$> between (string "(") (string ")") (many (term <|> list))
      in
        -- rec defers calling helper until it's actually needed.
        rec helper

    parse list ""
    -- Err ["expected \"(\""]

    parse list "()"
    -- Ok (EList [])

    parse list "(a (b c))"
    -- Ok (EList [ETerm "a", EList [ETerm "b", ETerm "c"]])

-}
rec : (() -> Parser s a) -> Parser s a
rec t = RecursiveParser (L.lazy (\() -> app (t ())))


{-| Transform both the result and error message of a parser. -}
bimap : (a -> b)
      -> (List String -> List String)
      -> Parser s a
      -> Parser s b
bimap fok ferr p =
  Parser <| \state stream ->
    case app p state stream of
      (rstate, rstream, Ok res) ->
        (rstate, rstream, Ok (fok res))

      (estate, estream, Err ms) ->
        (estate, estream, Err (ferr ms))


-- State management
-- ----------------
{-| Get the parser's state and pipe it into a parser. -}
withState : (s -> Parser s a) -> Parser s a
withState f =
  Parser <| \state stream ->
    app (f state) state stream


{-| Replace the parser's state. -}
putState : s -> Parser s ()
putState state =
  Parser <| \_ stream ->
    app (succeed ()) state stream


{-| Modify the parser's state. -}
modifyState : (s -> s) -> Parser s ()
modifyState f =
  Parser <| \state stream ->
    app (succeed ()) (f state) stream


{-| Get the current position in the input stream and pipe it into a parser. -}
withLocation : (ParseLocation -> Parser s a) -> Parser s a
withLocation f =
  Parser <| \state stream ->
    app (f <| currentLocation stream) state stream


{-| Get the current line and pipe it into a parser. -}
withLine : (Int -> Parser s a) -> Parser s a
withLine f =
  Parser <| \state stream ->
    app (f <| currentLine stream) state stream


{-| Get the current column and pipe it into a parser. -}
withColumn : (Int -> Parser s a) -> Parser s a
withColumn f =
  Parser <| \state stream ->
    app (f <| currentColumn stream) state stream


{-| Get the current `(line, column)` in the input stream. -}
currentLocation : InputStream -> ParseLocation
currentLocation stream =
  let
    lines = String.split "\n" stream.data

    find position currentLine lines =
      case lines of
        [] ->
          ParseLocation "" 1 position

        [line] ->
          ParseLocation line (currentLine + 1) position

        line :: lines ->
          let length = String.length line in
          if position >= length then
            find (position - length - 1) (currentLine + 1) lines
          else if currentLine == 0 then
            ParseLocation line 1 position
          else
            ParseLocation line currentLine (position - 1)
  in
    find stream.position 0 lines


{-| Get the current source line in the input stream. -}
currentSourceLine : InputStream -> String
currentSourceLine = currentLocation >> .source


{-| Get the current line in the input stream. -}
currentLine : InputStream -> Int
currentLine = currentLocation >> .line


{-| Get the current column in the input stream. -}
currentColumn : InputStream -> Int
currentColumn = currentLocation >> .column


-- Transformers
-- ------------
{-| Transform the result of a parser.

    let
      parser =
        string "a"
          |> map String.toUpper
    in
      parse parser "a"
      -- Ok "A"

-}
map : (a -> b) -> Parser s a -> Parser s b
map f p = bimap f identity p


{-| Transform the error of a parser.

    let
      parser =
        string "a"
          |> mapError (always ["bad input"])
    in
      parse parser b
      -- Err ["bad input"]

-}
mapError : (List String -> List String) -> Parser s a -> Parser s a
mapError = bimap identity


{-| Sequence two parsers, passing the result of the first parser to a
function that returns the second parser. The value of the second
parser is returned on success.

    import Combine.Num exposing (int)

    choosy : Parser s String
    choosy =
      let
        createParser n =
          if n % 2 == 0 then
            string " is even"
          else
            string " is odd"
      in
        int
          |> andThen createParser

    parse choosy "1 is odd"
    -- Ok " is odd"

    parse choosy "2 is even"
    -- Ok " is even"

    parse choosy "1 is even"
    -- Err ["expected \" is odd\""]

-}
andThen : (a -> Parser s b) -> Parser s a -> Parser s b
andThen f p =
  Parser <| \state stream ->
    case app p state stream of
      (rstate, rstream, Ok res) ->
        app (f res) rstate rstream

      (estate, estream, Err ms) ->
        (estate, estream, Err ms)


{-| Sequence two parsers.

    import Maybe
    import Result
    import String

    toInt : String -> Int
    toInt =
      String.toInt
        >> Result.toMaybe
        >> Maybe.withDefault 0

    num : Parser s Int
    num =
      regex "[0-9]+"
        |> map toInt

    sum : Parser s Int
    sum =
      (num <* string "+")
        |> map (+)
        |> andMap num

    parse sum "1+2"
    -- Ok 3

-}
andMap : Parser s a -> Parser s (a -> b) -> Parser s b
andMap rp lp = lp >>= flip map rp


{-| Run a list of parsers in sequence, accumulating the results.  The
main use case for this parser is when you want to combine a list of
parsers into a single, top-level, parser.  For most use cases, you'll
want to use one of the other combinators instead.

    parse (sequence [string "a", string "b"]) "ab"
    -- Ok ["a", "b"]

    parse (sequence [string "a", string "b"]) "ac"
    -- Err ["expected \"b\""]

 -}
sequence : List (Parser s a) -> Parser s (List a)
sequence ps =
  let
    accumulate acc ps state stream =
      case ps of
        [] ->
          (state, stream, Ok (List.reverse acc))

        p::ps ->
          case app p state stream of
            (rstate, rstream, Ok res) ->
              accumulate (res :: acc) ps rstate rstream

            (estate, estream, Err ms) ->
              (estate, estream, Err ms)
  in
    Parser <| \state stream ->
      accumulate [] ps state stream


-- Combinators
-- -----------
{-| Fail without consuming any input.

    parse (fail "some error") "hello"
    -- Err ["some error"]

-}
fail : String -> Parser s a
fail m =
  Parser <| \state stream ->
    (state, stream, Err [m])


emptyErr : Parser s a
emptyErr =
  Parser <| \state stream ->
    (state, stream, Err [])


{-| Return a value without consuming any input.

    parse (succeed 1) "a"
    -- Ok 1

-}
succeed : a -> Parser s a
succeed res =
  Parser <| \state stream ->
    (state, stream, Ok res)


{-| Parse an exact string match.

    parse (string "hello") "hello world"
    -- Ok "hello"

    parse (string "hello") "goodbye"
    -- Err ["expected \"hello\""]

-}
string : String -> Parser s String
string s =
  Parser <| \state stream ->
    if String.startsWith s stream.input
    then
      let
        len = String.length s
        rem = String.dropLeft len stream.input
        pos = stream.position + len
      in (state, {stream | input = rem, position = pos}, Ok s)
    else (state, stream, Err ["expected " ++ (toString s)])


{-| Parse a Regex match.

Regular expressions must match from the beginning of the input and their
subgroups are ignored. A `^` is added implicitly to the beginning of
every pattern unless one already exists.

    parse (regex "a+") "aaaaab"
    -- Ok "aaaaa"

-}
regex : String -> Parser s String
regex pat =
  let
    pattern =
      if String.startsWith "^" pat
      then pat
      else "^" ++ pat
  in
    Parser <| \state stream ->
      case Regex.find (Regex.AtMost 1) (Regex.regex pattern) stream.input of
        [match] ->
          let
            len = String.length match.match
            rem = String.dropLeft len stream.input
            pos = stream.position + len
          in (state, {stream | input = rem, position = pos }, Ok match.match)
        _ ->
          (state, stream, Err ["expected input matching Regexp /" ++ pattern ++ "/"])


{-| Consume input while the predicate matches.

    parse (while ((/=) ' ')) "test 123"
    -- Ok "test"

-}
while : (Char -> Bool) -> Parser s String
while pred =
  let
    accumulate acc state stream =
      case String.uncons stream.input of
        Just (h, rest) ->
          if pred h
          then
            let
              c = String.cons h ""
              pos = stream.position + 1
            in
              accumulate (acc ++ c) state {stream | input = rest, position = pos}
          else
            (state, stream, acc)

        Nothing ->
          (state, stream, acc)
  in
    Parser <| \state stream ->
      let
        (rstate, rstream, res) = accumulate "" state stream
      in
        (rstate, rstream, Ok res)


{-| Fail when the input is not empty.

    parse end ""
    -- Ok ()

    parse end "a"
    -- Err ["expected end of input"]

-}
end : Parser s ()
end =
  Parser <| \state stream ->
    if stream.input == ""
    then (state, stream, Ok ())
    else (state, stream, Err ["expected end of input"])


{-| Apply a parser without consuming any input on success. -}
lookAhead : Parser s a -> Parser s a
lookAhead p =
  Parser <| \state stream ->
    case app p state stream of
      (rstate, _, Ok res) ->
        (rstate, stream, Ok res)

      err ->
        err


{-| Choose between two parsers.

    parse (or (string "a") (string "b")) "a"
    -- Ok "a"

    parse (or (string "a") (string "b")) "b"
    -- Ok "b"

    parse (or (string "a") (string "b")) "c"
    -- Err ["expected \"a\"", "expected \"b\""]

-}
or : Parser s a -> Parser s a -> Parser s a
or lp rp =
  Parser <| \state stream ->
    case app lp state stream of
      ((_, _, Ok _) as res) ->
        res

      (_, _, Err lms) ->
        case app rp state stream of
          ((_, _, Ok _) as res) ->
            res

          (_, _, Err rms) ->
            (state, stream, Err (lms ++ rms))


{-| Choose between a list of parsers.

    parse (choice [string "a", string "b"]) "a"
    -- Ok "a"

    parse (choice [string "a", string "b"]) "b"
    -- Ok "b"

-}
choice : List (Parser s a) -> Parser s a
choice xs =
  List.foldr or emptyErr xs


{-| Return a default value when the given parser fails.

    letterA : Parser s String
    letterA = optional "a" (string "a")

    parse letterA "a"
    -- Ok "a"

    parse letterA "b"
    -- Ok "a"

-}
optional : a -> Parser s a -> Parser s a
optional res p =
  p <|> succeed res


{-| Wrap the return value into a `Maybe`. Returns `Nothing` on failure.

    parse (maybe (string "a")) "a"
    -- Ok (Just "a")

    parse (maybe (string "a")) "b"
    -- Ok Nothing

-}
maybe : Parser s a -> Parser s (Maybe a)
maybe p =
  Parser <| \state stream ->
    case app p state stream of
      (rstate, rstream, Ok res) ->
        (rstate, rstream, Ok (Just res))

      _ ->
        (state, stream, Ok Nothing)


{-| Apply a parser until it fails and return a list of the results.

    parse (many (string "a")) "aaab"
    -- Ok ["a", "a", "a"]

    parse (many (string "a")) ""
    -- Ok []

-}
many : Parser s a -> Parser s (List a)
many p =
  let
    accumulate acc state stream =
      case app p state stream of
        (rstate, rstream, Ok res) ->
          if stream == rstream then
            (rstate, rstream, List.reverse acc)
          else
            accumulate (res :: acc) rstate rstream

        _ ->
          (state, stream, List.reverse acc)
  in
    Parser <| \state stream ->
      let
        (rstate, rstream, res) = accumulate [] state stream
      in
        (rstate, rstream, Ok res)


{-| Parse at least one result.

    parse (many1 (string "a")) "a"
    -- Ok ["a"]

    parse (many1 (string "a")) ""
    -- Err ["expected \"a\""]

-}
many1 : Parser s a -> Parser s (List a)
many1 p =
  (::) <$> p <*> many p


{-| Apply parser `p` zero or more times until parser `end`
succeeds. On success, the list of `p`'s results is returned.

    string "<!--" *> manyTill anyChar (string "-->")

-}
manyTill : Parser s a -> Parser s end -> Parser s (List a)
manyTill p end =
  let
    accumulate acc state stream =
      case app end state stream of
        (rstate, rstream, Ok _) ->
          (rstate, rstream, Ok (List.reverse acc))

        (estate, estream, Err ms) ->
          case app p state stream of
            (rstate, rstream, Ok res) ->
              accumulate (res :: acc) rstate rstream

            _ ->
              (estate, estream, Err ms)
  in
    Parser (accumulate [])


{-| Parser zero or more occurences of one parser separated by another.

    parse (sepBy (string ",") (string "a")) "b"
    -- Ok []

    parse (sepBy (string ",") (string "a")) "a,a,a"
    -- Ok ["a", "a", "a"]

    parse (sepBy (string ",") (string "a")) "a,a,b"
    -- Ok ["a", "a"]

-}
sepBy : Parser s x -> Parser s a -> Parser s (List a)
sepBy sep p =
  sepBy1 sep p <|> succeed []


{-| Parse one or more occurences of one parser separated by another. -}
sepBy1 : Parser s x -> Parser s a -> Parser s (List a)
sepBy1 sep p =
  (::) <$> p <*> many (sep *> p)


{-| Parse zero or more occurences of one parser separated and
optionally ended by another.

    parse (sepEndBy (string ",") (string "a")) "a,a,a,"
    -- Ok ["a", "a", "a"]

-}
sepEndBy : Parser s x -> Parser s a -> Parser s (List a)
sepEndBy sep p =
  sepEndBy1 sep p <|> succeed []


{-| Parse one or more occurences of one parser separated and
optionally ended by another.

    parse (sepEndBy1 (string ",") (string "a")) ""
    -- Err ["expected \"a\""]

    parse (sepEndBy1 (string ",") (string "a")) "a"
    -- Ok ["a"]

    parse (sepEndBy1 (string ",") (string "a")) "a,"
    -- Ok ["a"]

-}
sepEndBy1 : Parser s x -> Parser s a -> Parser s (List a)
sepEndBy1 sep p =
  sepBy1 sep p <* maybe sep


{-| Apply a parser and skip its result. -}
skip : Parser s x -> Parser s ()
skip p = () <$ p


{-| Apply a parser and skip its result many times. -}
skipMany : Parser s x -> Parser s ()
skipMany p = () <$ many (skip p)


{-| Apply a parser and skip its result at least once. -}
skipMany1 : Parser s x -> Parser s ()
skipMany1 p = () <$ many1 (skip p)


{-| Parse one or more occurences of `p` separated by `op`, recursively
apply all functions returned by `op` to the values returned by `p`. See
the `examples/Calc.elm` file for an example.
-}
chainl : Parser s (a -> a -> a) -> Parser s a -> Parser s a
chainl op p =
  let
    accumulate x =
      (op
        |> andThen (\f -> p
        |> andThen (\y -> accumulate (f x y)))) <|> succeed x
  in
    andThen accumulate p


{-| Similar to `chainl` but functions of `op` are applied in
right-associative order to the values of `p`. -}
chainr : Parser s (a -> a -> a) -> Parser s a -> Parser s a
chainr op p =
  let
    accumulate x =
      (op
        |> andThen (\f -> p
        |> andThen accumulate
        |> andThen (\y -> succeed (f x y)))) <|> succeed x
  in
    andThen accumulate p


{-| Parse `n` occurences of `p`. -}
count : Int -> Parser s a -> Parser s (List a)
count n p =
  let
    accumulate x acc =
      if x <= 0
      then succeed (List.reverse acc)
      else andThen (\res -> accumulate (x - 1) (res :: acc)) p
  in
    accumulate n []


{-| Parse something between two other parsers.

The parser

    between (string "(") (string ")") (string "a")

is equivalent to the parser

    string "(" *> string "a" <* string ")"
-}
between : Parser s l -> Parser s r -> Parser s a -> Parser s a
between lp rp p = lp *> p <* rp


{-| Parse something between parentheses. -}
parens : Parser s a -> Parser s a
parens = between (string "(") (string ")")


{-| Parse something between braces `{}`. -}
braces : Parser s a -> Parser s a
braces = between (string "{") (string "}")


{-| Parse something between square brackets `[]`. -}
brackets : Parser s a -> Parser s a
brackets = between (string "[") (string "]")


{-| Parse zero or more whitespace characters. -}
whitespace : Parser s String
whitespace = regex "[ \t\r\n]*" <?> "whitespace"


-- Infix operators
-- ---------------
{-| Variant of `Combine.mapError` that replaces the Parser's error
with a List of a single string.

    -- Err ["gimme an 'a'"]
    parse (string "a" <?> "gimme an 'a'") "b"

-}
(<?>) : Parser s a -> String -> Parser s a
(<?>) p m = mapError (always [m]) p


{-| Flipped synonym for `andThen`. -}
(>>=) : Parser s a -> (a -> Parser s b) -> Parser s b
(>>=) = flip andThen


{-| Synonym for `map`. -}
(<$>) : (a -> b) -> Parser s a -> Parser s b
(<$>) = map


{-| Variant of `map` that ignores the Parser's result. -}
(<$) : a -> Parser s x -> Parser s a
(<$) res = map (\_ -> res)


{-| Variant of `map` that ignores the Parser's result. -}
($>) : Parser s x -> a -> Parser s a
($>) = flip (<$)


{-| Flipped synonym for `andMap`. -}
(<*>) : Parser s (a -> b) -> Parser s a -> Parser s b
(<*>) = flip andMap


{-| Join two parsers, ignoring the result of the one on the right.

    unsuffix : Parser s String
    unsuffix =
      regex "[a-z]"
        <* regex "[!?]"

    parse unsuffix "a!"
    -- Ok "a"

-}
(<*) : Parser s a -> Parser s x -> Parser s a
(<*) lp rp =
  lp
    |> map always
    |> andMap rp


{-| Join two parsers, ignoring the result of the one on the left.

    unprefix : Parser s String
    unprefix =
      string ">"
        *> while ((==) ' ')
        *> while ((/=) ' ')

    parse unprefix "> a"
    -- Ok "a"

-}
(*>) : Parser s x -> Parser s a -> Parser s a
(*>) lp rp =
  lp
    |> map (flip always)
    |> andMap rp


{-| Synonym for `or`. -}
(<|>) : Parser s a -> Parser s a -> Parser s a
(<|>) = or


-- Fixities
infix  0 <?>
infixl 1 >>=
infixr 1 <|>
infixl 4 <$>
infixl 4 <$
infixl 4 $>
infixl 4 <*>
infixl 4 <*
infixl 4 *>
