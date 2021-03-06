module StateManagement where
import Brick
import Control.Monad.IO.Class
import Data.Maybe (fromJust)
import Lens.Micro.Platform
import Recents
import States hiding (cardState)
import Stack hiding (head)
import qualified Brick.Widgets.List as L
import qualified Data.Vector as Vec
import qualified Data.Map.Strict as M
import qualified Stack

getMode :: State -> Mode
getMode (MainMenuState     _) = MainMenu
getMode (SettingsState     _) = Settings
getMode (InfoState         _) = Info
getMode (CardSelectorState _) = CardSelector
getMode (FileBrowserState  _) = FileBrowser
getMode (CardsState        _) = Cards

getState :: GlobalState -> State
getState = fromJust . safeGetState

updateState :: GlobalState -> State -> GlobalState
updateState gs s = gs & states %~ M.insert (getMode s) s

updateMMS :: GlobalState -> MMS -> GlobalState
updateMMS gs s = updateState gs (MainMenuState s)

updateSS :: GlobalState -> SS -> GlobalState
updateSS gs s = updateState gs (SettingsState s)

updateIS :: GlobalState -> IS -> GlobalState
updateIS gs s = updateState gs (InfoState s)

updateCS :: GlobalState -> CS -> GlobalState
updateCS gs s = updateState gs (CardsState s)

updateCSS :: GlobalState -> CSS -> GlobalState
updateCSS gs s = updateState gs (CardSelectorState s)

updateInfo :: GlobalState -> IS -> GlobalState
updateInfo gs s = updateState gs (InfoState s)

updateFBS :: GlobalState -> FBS -> GlobalState
updateFBS gs s = updateState gs (FileBrowserState s)

goToState :: GlobalState -> State -> GlobalState
goToState gs s = gs & states %~ M.insert (getMode s) s
                    & stack  %~ insert (getMode s)

moveToState :: GlobalState -> State -> GlobalState 
moveToState gs = goToState (popState gs)

popState :: GlobalState -> GlobalState
popState gs = let
  s    = gs ^. stack
  top  = Stack.head s
  s'   = Stack.pop s in
    gs & states %~ M.delete top
       & stack  .~ s'

safeGetState :: GlobalState -> Maybe State
safeGetState gs = do
  key <- safeHead (gs ^. stack)
  M.lookup key (gs ^. states)

goToModeOrQuit :: GlobalState -> Mode -> EventM n (Next GlobalState)
goToModeOrQuit gs mode = 
  maybe (halt gs) (continue . goToState gs) $ M.lookup mode (gs ^. states) 

moveToModeOrQuit :: GlobalState -> Mode -> EventM n (Next GlobalState)
moveToModeOrQuit gs mode = 
  maybe (halt gs) (continue . moveToState gs) $ M.lookup mode (gs ^. states) 

moveToModeOrQuit' :: (State -> IO State) -> GlobalState -> Mode -> EventM n (Next GlobalState)
moveToModeOrQuit' f gs mode = 
  maybe (halt gs) (\s -> continue . moveToState gs =<< liftIO (f s)) $ M.lookup mode (gs ^. states) 

refreshRecents :: CSS -> IO CSS
refreshRecents s = do
  rs <- getRecents
  let prettyRecents = shortenFilepaths (toList rs)
      options       = Vec.fromList (prettyRecents ++ ["Select file from system"])
  return $ s & recents .~ rs
             & list    .~ L.list Ordinary options 1