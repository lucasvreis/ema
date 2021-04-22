{-# LANGUAGE TypeApplications #-}

-- | An advanced example demonstrating how to build something like neuron
--
-- Create a nice a looking website with calendar view and outlines out of your
-- daily notes written in org-mode format.
module Ema.Example.Ex03_Diary where

import Control.Concurrent (threadDelay)
import Control.Exception (finally)
import qualified Data.LVar as LVar
import qualified Data.Map.Strict as Map
import Data.Org (OrgFile)
import qualified Data.Org as Org
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time (Day, defaultTimeLocale, parseTimeM)
import Ema (Ema (..), Slug (unSlug), routeUrl, runEma)
import qualified Ema.Helper.Tailwind as Tailwind
import qualified Shower
import System.FSNotify (Event (..), watchDir, withManager)
import System.FilePath (takeFileName, (</>))
import System.FilePattern.Directory (getDirectoryFiles)
import Text.Blaze.Html5 ((!))
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A

data Route
  = Index
  | OnDay Day
  deriving (Show)

newtype Diary = Diary {unDiary :: Map Day OrgFile}
  deriving (Show)

instance Ema Diary Route where
  encodeRoute = \case
    Index -> mempty
    OnDay day -> one $ show day
  decodeRoute = \case
    [] -> Just Index
    [s] -> OnDay <$> parseDay (toString $ unSlug s)
    _ -> Nothing
  staticRoutes diary =
    Index : fmap OnDay (Map.keys $ unDiary diary)

parseDay :: String -> Maybe Day
parseDay =
  parseTimeM False defaultTimeLocale "%Y-%m-%d"

main :: IO ()
main = do
  mainWith "src/Ema/Example/Diary"

mainWith :: FilePath -> IO ()
mainWith folder = do
  runEma render $ \model -> do
    LVar.set model =<< loadDiary
    watchAndUpdate model
  where
    -- Read diary folder on startup.
    loadDiary :: IO Diary
    loadDiary = do
      putStrLn $ "Loading .org files from " <> folder
      fs <- getDirectoryFiles folder (one "*.org")
      Diary . Map.fromList . catMaybes <$> forM fs (parseDailyNote . (folder </>))

    -- Watch the diary folder, and update our in-memory model incrementally.
    watchAndUpdate :: LVar.LVar Diary -> IO ()
    watchAndUpdate model = do
      putStrLn $ "Watching .org files in " <> folder
      withManager $ \mgr -> do
        stop <- watchDir mgr folder (const True) $ \event -> do
          print event
          let updateFile fp = do
                parseDailyNote fp >>= \case
                  Nothing -> pure ()
                  Just (day, org) -> do
                    putStrLn $ "Update: " <> show day
                    LVar.modify model $ Diary . Map.insert day org . unDiary
              deleteFile fp = do
                whenJust (parseDailyNoteFilepath fp) $ \day -> do
                  putStrLn $ "Delete: " <> show day
                  LVar.modify model $ Diary . Map.delete day . unDiary
          case event of
            Added fp _ isDir -> unless isDir $ updateFile fp
            Modified fp _ isDir -> unless isDir $ updateFile fp
            Removed fp _ isDir -> unless isDir $ deleteFile fp
            Unknown fp _ _ -> updateFile fp
        threadDelay maxBound
          `finally` stop

    parseDailyNote :: FilePath -> IO (Maybe (Day, OrgFile))
    parseDailyNote f =
      case parseDailyNoteFilepath f of
        Nothing -> pure Nothing
        Just day -> do
          s <- readFileText f
          pure $ (day,) <$> Org.org s

    parseDailyNoteFilepath :: FilePath -> Maybe Day
    parseDailyNoteFilepath f =
      parseDay . toString =<< T.stripSuffix ".org" (toText $ takeFileName f)

render :: Diary -> Route -> LByteString
render diary r = do
  Tailwind.layout (H.title pageTitle) $
    H.div ! A.class_ "container mx-auto" $ do
      let heading =
            H.header
              ! A.class_ "text-4xl my-2 py-2 font-bold text-center bg-purple-50 shadow"
      case r of
        Index -> do
          heading "My Diary"
          H.div ! A.class_ "" $
            forM_ (sortOn Down $ Map.keys $ unDiary diary) $ \day ->
              H.li $ routeElem (OnDay day) $ H.toMarkup @Text (show day)
        OnDay day -> do
          heading $ show day
          routeElem Index "Back to Index"
          maybe "not found" renderOrg (Map.lookup day $ unDiary diary)
      H.footer ! A.class_ "mt-2 text-center border-t-2 text-gray-500" $ do
        "Powered by "
        H.a ! A.href "https://github.com/srid/ema" ! A.target "blank_" $ "Ema"
  where
    pageTitle = case r of
      Index -> "My Diary"
      OnDay day -> show day <> " -- My Diary"
    routeElem r' w =
      H.a ! A.class_ "text-xl text-purple-500 hover:underline" ! routeHref r' $ w
    routeHref r' =
      A.href (fromString . toString $ routeUrl r')

renderOrg :: OrgFile -> H.Html
renderOrg _org@(Org.OrgFile orgMeta orgDoc) = do
  let heading = H.header ! A.class_ "text-2xl my-2 font-bold"
  unless (null orgMeta) $ do
    heading "Meta"
    renderMeta orgMeta
  heading "Doc"
  -- Debug dump
  -- H.pre $ H.toMarkup (Shower.shower org)
  renderOrgDoc orgDoc
  where
    renderMeta :: Map Text Text -> H.Html
    renderMeta meta = do
      H.table ! A.class_ "table-auto" $ do
        let td cls = H.td ! A.class_ ("border px-4 py-2 " <> cls)
        forM_ (Map.toList meta) $ \(k, v) ->
          H.tr $ do
            td "font-bold" $ H.toMarkup k
            td "font-mono" $ H.toMarkup v

    renderOrgDoc :: Org.OrgDoc -> H.Html
    renderOrgDoc (Org.OrgDoc blocks sections) = do
      H.ul ! A.class_ "list-disc ml-8" $ do
        whenNotNull blocks $ \_ -> do
          H.header ! A.class_ "text-2xl font-bold" $ "Blocks"
          H.pre $ H.toMarkup (Shower.shower blocks)
        whenNotNull sections $ \_ -> do
          forM_ sections renderSection

    renderSection :: Org.Section -> H.Html
    renderSection (Org.Section heading tags doc) = do
      H.li $ do
        forM_ heading $ \s ->
          renderWords s >> " "
        forM_ tags renderTag
        renderOrgDoc doc

    renderTag :: Text -> H.Html
    renderTag tag =
      H.span
        ! A.class_ "border-1 p-0.5 bg-purple-200 font-bold rounded"
        ! A.title "Tag"
        $ H.toMarkup tag

    renderWords :: Org.Words -> H.Markup
    renderWords ws = do
      let s = Org.prettyWords ws
      if s `Set.member` Set.fromList ["TODO", "DONE"]
        then
          H.span
            ! A.class_ "border-1 p-0.5 bg-gray-600 text-white"
            ! A.title "Keyword"
            $ H.toMarkup s
        else H.toMarkup s
