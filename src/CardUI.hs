{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE TemplateHaskell #-}
module CardUI (runCardUI) where

import Brick
import BrickHelpers
import Lens.Micro.Platform
import Types
import Data.Char (isSeparator, isSpace)
import Data.List (dropWhileEnd)
import Data.Map.Strict (Map)
import Text.Wrap
import Data.Text (pack)
import Debug.Trace (trace)
import System.IO.Unsafe (unsafePerformIO)
import qualified Data.Text as T
import qualified Data.Map.Strict as M
import qualified Brick.Widgets.Border as B
import qualified Brick.Widgets.Border.Style as BS
import qualified Brick.Widgets.Center as C
import qualified Graphics.Vty as V

type Event = ()
type Name = ()

data CardState = 
    DefinitionState
  { _flipped        :: Bool }
  | MultipleChoiceState
  { _selected       :: Int
  , _nChoices       :: Int
  , _tried          :: Map Int Bool      -- indices of tried choices
  }
  | OpenQuestionState
  { _gapInput       :: Map Int String
  , _selectedGap    :: Int
  , _nGaps          :: Int
  , _entered        :: Bool
  , _correctGaps    :: Map Int Bool
  }

data State = State
  { _cards          :: [Card]     -- list of flashcards
  , _index          :: Int        -- current card index
  , _nCards         :: Int        -- number of cards
  , _currentCard    :: Card
  , _cardState      :: CardState
  , _incorrectCards :: [Int]      -- list of indices of incorrect answers
  }

makeLenses ''CardState
makeLenses ''State

defaultCardState :: Card -> CardState
defaultCardState Definition{} = DefinitionState { _flipped = False }
defaultCardState (MultipleChoice _ _ ics) = MultipleChoiceState 
  { _selected = 0
  , _nChoices = length ics + 1
  , _tried = M.fromList [(i, False) | i <- [0..length ics]]}
defaultCardState (OpenQuestion _ perforated) = OpenQuestionState 
  { _gapInput = M.empty
  , _selectedGap = 0
  , _nGaps = nGapsInPerforated perforated
  , _entered = False
  , _correctGaps = M.fromList [(i, False) | i <- [0..nGapsInPerforated perforated - 1]] }


app :: App State Event Name
app = App 
  { appDraw = drawUI
  , appChooseCursor = showFirstCursor
  , appHandleEvent = handleEvent
  , appStartEvent = return
  , appAttrMap = const theMap
  }

drawUI :: State -> [Widget Name]
drawUI s =  [drawCardUI s <=> drawInfo]

drawInfo :: Widget Name
drawInfo = str "ESC: quit"

drawProgress :: State -> Widget Name
drawProgress s = C.hCenter $ str (show (s^.index + 1) ++ "/" ++ show (s^.nCards))

drawHeader :: String -> Widget Name
drawHeader title = withAttr titleAttr $
                   padLeftRight 1 $
                   hCenteredStrWrap title

drawDescr :: String -> Widget Name
drawDescr descr = padLeftRight 1 $
  strWrapWith (WrapSettings {preserveIndentation=False, breakLongWords=True}) descr'
    where
      descr' = dropWhileEnd isSpace descr

listMultipleChoice :: CorrectOption -> [IncorrectOption] -> [String]
listMultipleChoice c = reverse . listMultipleChoice' [] 0 c
  where listMultipleChoice' opts i c@(CorrectOption j cStr) [] = 
          if i == j
            then cStr : opts
            else opts
        listMultipleChoice' opts i c@(CorrectOption j cStr) ics@(IncorrectOption icStr : ics') = 
          if i == j
            then listMultipleChoice' (cStr  : opts) (i+1) c ics
            else listMultipleChoice' (icStr : opts) (i+1) c ics'

drawCardUI :: State -> Widget Name
drawCardUI s = joinBorders $ drawCardBox $ (<=> drawProgress s) $
  case (s ^. cards) !! (s ^. index) of
    Definition title descr -> drawHeader title <=> B.hBorder <=> drawHintedDef s descr <=> str " "
                              
    MultipleChoice question correct others -> drawHeader question <=> B.hBorder <=> drawOptions s (listMultipleChoice correct others)

    OpenQuestion title perforated -> drawHeader title <=> B.hBorder <=> padLeftRight 1 (drawPerforated s perforated <=> str " ")


applyWhen :: Bool -> (a -> a) -> a -> a
applyWhen predicate action = if predicate then action else id

applyUnless :: Bool -> (a -> a) -> a -> a
applyUnless p = applyWhen (not p)

drawHintedDef :: State -> String -> Widget Name
drawHintedDef s def = case s ^. cardState of
  DefinitionState {_flipped=f} -> if f then drawDescr def else drawDescr [if isSeparator char || char == '\n' then char else '_' | char <- def]
  _ -> error "impossible: " 

drawDef:: State -> String -> Widget Name
drawDef s def = case s ^. cardState of
  DefinitionState {_flipped=f} -> if f then drawDescr def else drawDescr [if char == '\n' then char else ' ' | char <- def]
  _ -> error "impossible: " 

drawOptions :: State -> [String] -> Widget Name
drawOptions s options = case (s ^. cardState, s^. currentCard) of
  (MultipleChoiceState {_selected=i, _tried=kvs}, MultipleChoice _ (CorrectOption k _) _)  -> vBox formattedOptions
                  
             where formattedOptions :: [Widget Name]
                   formattedOptions = [ coloring $ drawDescr (if i==j then "* " ++ opt else opt) |
                                        (j, opt) <- zip [0..] options,
                                        let chosen = M.findWithDefault False j kvs 
                                            coloring = case (chosen, j==k) of
                                              (False, _)    -> id
                                              (True, False) -> withAttr incorrectOptAttr
                                              (True, True)  -> withAttr correctOptAttr
                                          ]
  _                                  -> error "impossible"

drawPerforated :: State -> Perforated -> Widget Name
drawPerforated s p = drawSentence s $ perforatedToSentence p

drawSentence :: State -> Sentence -> Widget Name
drawSentence state sentence = Widget Greedy Fixed $ do
  c <- getContext
  let w = c^.availWidthL
  render $ makeSentenceWidget w state sentence

makeSentenceWidget :: Int -> State -> Sentence -> Widget Name
makeSentenceWidget w state = vBox . fst . makeSentenceWidget' 0 0
  where
    makeSentenceWidget' :: Int -> Int -> Sentence -> ([Widget Name], Bool)
    makeSentenceWidget' padding _ (Normal s) = let (ws, _, fit) = wrapStringWithPadding padding w s in (ws, fit) 
    makeSentenceWidget' padding i (Perforated pre gapSolution post) = case state ^. cardState of
      OpenQuestionState {_gapInput = kvs, _selectedGap=j, _entered=submitted, _correctGaps=cgs} ->
        let (ws, n, fit') = wrapStringWithPadding padding w pre
            gap = M.findWithDefault "" i kvs
            n' =  w - n - length gap 

            cursor :: Widget Name -> Widget Name
            -- i is the index of the gap that we are drawing; j is the gap that is currently selected
            cursor = if i == j then showCursor () (Location (length gap, 0)) else id

            correct = M.findWithDefault False i cgs
            coloring = case (submitted, correct) of
              (False, _) -> withAttr gapAttr
              (True, False) -> withAttr incorrectGapAttr
              (True, True) -> withAttr correctGapAttr
              
            gapWidget = cursor $ coloring (str gap) in

              if n' >= 0 
                then let (ws1@(w':ws'), fit) = makeSentenceWidget' (w-n') (i+1) post in
                  if fit then ((ws & _last %~ (<+> (gapWidget <+> w'))) ++ ws', fit')
                  else ((ws & _last %~ (<+> gapWidget)) ++ ws1, fit')
              else let (ws1@(w':ws'), fit) = makeSentenceWidget' (length gap) (i+1) post in
                if fit then (ws ++ [gapWidget <+> w'] ++ ws', fit')
                else (ws ++ [gapWidget] ++ ws1, fit')
      _ -> error "PANIC!"

wrapStringWithPadding :: Int -> Int -> String -> ([Widget Name], Int, Bool)
wrapStringWithPadding padding w s
  | null (words s) = ([str ""], padding, True)
  | otherwise = if length (head (words s)) < w - padding then
    let startsWithSpace = head s == ' ' 
        s' = if startsWithSpace then " " <> replicate padding 'X' <> tail s else replicate padding 'X' ++ s
        lastLetter = last s
        postfix = if lastLetter == ' ' then T.pack [lastLetter] else T.empty
        ts = wrapTextToLines defaultWrapSettings w (pack s') & ix 0 %~ (if startsWithSpace then (T.pack " " `T.append`) . T.drop (padding + 1) else T.drop padding)
        ts' = ts & _last %~ (`T.append` postfix)
        padding' = T.length (last ts') + (if length ts' == 1 then 1 else 0) * padding in
          (map txt (filter (/=T.empty) ts'), padding', True)
  else
    let lastLetter = last s
        (x: xs) = s
        s' = if x == ' ' then xs else s
        postfix = if lastLetter == ' ' then T.pack [lastLetter] else T.empty
        ts = wrapTextToLines defaultWrapSettings w (pack s')
        ts' = ts & _last %~ (`T.append` postfix) in
    (map txt (filter (/=T.empty) ts'), T.length (last ts'), False)

debugToFile :: String -> a -> a
debugToFile s expr = unsafePerformIO $ do
  appendFile "log.txt" s
  return expr

drawCardBox :: Widget Name -> Widget Name
drawCardBox w = C.center $
                withBorderStyle BS.unicodeRounded $
                B.border $
                withAttr textboxAttr $
                hLimitPercent 60 w

handleEvent :: State -> BrickEvent Name Event -> EventM Name (Next State)
handleEvent s (VtyEvent ev) = case ev of
  V.EvKey V.KEsc []                -> halt s
  V.EvKey (V.KChar 'c') [V.MCtrl]  -> halt s
  V.EvKey V.KRight [V.MCtrl]       -> next s
  V.EvKey V.KLeft  [V.MCtrl]       -> previous s
  -- V.EvKey (V.KChar ' ') []         -> next s

  ev -> case (s ^. cardState, s ^. currentCard) of
    (MultipleChoiceState {_selected = i, _nChoices = nChoices, _tried = kvs}, MultipleChoice _ (CorrectOption j _) _) ->
      case ev of
        V.EvKey V.KUp [] -> continue up
        V.EvKey (V.KChar 'k') [] -> continue up
        V.EvKey V.KDown [] -> continue down 
        V.EvKey (V.KChar 'j') [] -> continue down

        V.EvKey V.KEnter [] ->
            if frozen
              then next s
              else continue $ s & cardState.tried %~ M.insert i True

        _ -> continue s

      where frozen = M.findWithDefault False j kvs
        
            down = if i < nChoices - 1 && not frozen
                     then s & (cardState.selected) +~ 1
                     else s

            up = if i > 0 && not frozen
                   then s & (cardState.selected) -~ 1
                   else s

    (DefinitionState{_flipped = f}, _) ->
      case ev of
        V.EvKey V.KEnter [] -> 
          if f
            then next s 
            else continue $ s & cardState.flipped %~ not
        _ -> continue s
    
    (OpenQuestionState {_selectedGap = i, _nGaps = n, _gapInput = kvs, _correctGaps = cGaps}, OpenQuestion _ perforated) ->
      case ev of
        V.EvKey (V.KChar '\t') [] -> continue $ 
          if i < n - 1
            then s & (cardState.selectedGap) +~ 1
            else s & (cardState.selectedGap) .~ 0
        
        V.EvKey V.KRight [] -> continue $ 
          if i < n - 1
            then s & (cardState.selectedGap) +~ 1
            else s

        V.EvKey V.KLeft [] -> continue $ 
          if i > 0
            then s & (cardState.selectedGap) -~ 1
            else s

        V.EvKey (V.KChar c) [] -> continue $
          if correct then s else s & cardState.gapInput.at i.non "" %~ (++[c])
            where correct = M.foldr (&&) True cGaps

        V.EvKey V.KEnter [] -> if correct then next s else continue s'
            where correct :: Bool
                  sentence = perforatedToSentence perforated
                  gaps = sentenceToGaps sentence

                  s' = s & (cardState.correctGaps) %~ M.mapWithKey (\i _ -> gaps !! i == M.findWithDefault "" i kvs) & (cardState.entered) .~ True
                  -- correct = M.foldr (&&) True (s' ^. (cardState.correctGaps))
                  -- use above if you want to go to next card directly, if gaps were filled in correctly
                  correct = M.foldr (&&) True cGaps

        V.EvKey V.KBS [] -> continue $ s & cardState.gapInput.ix i %~ backspace
          where backspace "" = ""
                backspace xs = init xs
        _ -> continue s
      
    _ -> error "impossible"
handleEvent s _ = continue s
      
titleAttr :: AttrName
titleAttr = attrName "title"

textboxAttr :: AttrName
textboxAttr = attrName "textbox"

incorrectOptAttr :: AttrName
incorrectOptAttr = attrName "incorrect option"

correctOptAttr :: AttrName
correctOptAttr = attrName "correct option"

hiddenAttr :: AttrName
hiddenAttr = attrName "hidden"

gapAttr :: AttrName
gapAttr = attrName "gap"

incorrectGapAttr :: AttrName
incorrectGapAttr = attrName "incorrect gap"

correctGapAttr :: AttrName
correctGapAttr = attrName "correct gap"

theMap :: AttrMap
theMap = attrMap V.defAttr
  [ (titleAttr, fg V.yellow)
  , (textboxAttr, V.defAttr)
  , (incorrectOptAttr, fg V.red)
  , (correctOptAttr, fg V.green)
  , (incorrectGapAttr, fg V.red `V.withStyle` V.underline)
  , (correctGapAttr, fg V.green `V.withStyle` V.underline)
  , (hiddenAttr, fg V.black)
  , (gapAttr, V.defAttr `V.withStyle` V.underline)
  ]

runCardUI :: [Card] -> IO State
runCardUI cards = do
  let initialState = State { _cards = cards
                           , _index = 0
                           , _currentCard = head cards
                           , _cardState = defaultCardState (head cards)
                           , _nCards = length cards }
  defaultMain app initialState

next :: State -> EventM Name (Next State)
next s
  | s ^. index + 1 < length (s ^. cards) = continue . updateState $ s & index +~ 1
  | otherwise                            = halt s

previous :: State -> EventM Name (Next State)
previous s | s ^. index > 0 = continue . updateState $ s & index -~ 1
           | otherwise      = continue s

updateState :: State -> State
updateState s =
  let card = (s ^. cards) !! (s ^. index) in s
    & currentCard .~ card
    & cardState .~ defaultCardState card
