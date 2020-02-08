module Types where

--                     Word   Description
data Card = Definition String String
          | OpenQuestion String Perforated
          | MultipleChoice {
            mcQuestion   :: String,
            mcCorrect    :: CorrectOption,
            mcIncorrects :: [IncorrectOption]}
          -- | MultipleAnswer String (NE.NonEmpty Answer) 
  deriving Show

data Type = Incorrect | Correct
  deriving Show
data CorrectOption = CorrectOption Int String
  deriving Show
newtype IncorrectOption = IncorrectOption String
  deriving Show
data Answer = Answer Type String
  deriving Show

--                         Pre    Gap    Post
data Sentence = Perforated String String Sentence
              | Normal String
  deriving Show

nGapsInSentence :: Sentence -> Int
nGapsInSentence = nGapsInSentence' 0
nGapsInSentence' acc (Normal s) = acc
nGapsInSentence' acc (Perforated pre gap post) = nGapsInSentence' (1+acc) post

foldSentence :: (String -> a) -> (String -> String -> a -> a) -> Sentence -> a
foldSentence norm perf = f where
  f (Normal text) = norm text
  f (Perforated pre post sent) = perf pre post (f sent)

foldSentenceIndex :: (String -> Int -> a) -> (String -> String -> a -> Int -> a) -> Sentence -> a
foldSentenceIndex norm perf = f 0 where
  f i (Normal text) = norm text i
  f i (Perforated pre post sent) = perf pre post (f (i+1) sent) i

data Perforated = P String String Sentence
  deriving Show

perforatedToSentence :: Perforated -> Sentence
perforatedToSentence (P pre gap sentence) = Perforated pre gap sentence

nGapsInPerforated :: Perforated -> Int
nGapsInPerforated = nGapsInSentence . perforatedToSentence