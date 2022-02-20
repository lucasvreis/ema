module Ema.App
  ( runSite,
    runSite_,
    runSiteWithCli,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race_)
import Control.Monad.Logger
import Control.Monad.Logger.Extras
  ( colorize,
    logToStdout,
    runLoggerLoggingT,
  )
import Data.LVar (LVar)
import Data.LVar qualified as LVar
import Data.Some (Some (Some))
import Ema.CLI (Cli)
import Ema.CLI qualified as CLI
import Ema.Generate (generateSite)
import Ema.Server qualified as Server
import Ema.Site (Site (siteModelManager, siteRouteEncoder), runModelManager)
import System.Directory (getCurrentDirectory)

-- | Run the given Ema site, and return the generated files.
--
-- On live-server mode, this function will never return.
runSite :: forall r a. (Show r, Eq r) => Site a r -> IO [FilePath]
runSite site = do
  cli <- CLI.cliAction
  runSiteWithCli cli site

-- | Like `runSite` but throws away the result.
runSite_ :: forall r a. (Show r, Eq r) => Site a r -> IO ()
runSite_ = void . runSite

-- | Like @runSite@ but takes the CLI action
--
-- Useful if you are handling CLI arguments yourself.
runSiteWithCli :: forall r a. (Show r, Eq r) => Cli -> Site a r -> IO [FilePath]
runSiteWithCli cli site = do
  -- TODO: Allow library users to control logging levels, or colors.
  let logger = colorize logToStdout
  model :: LVar a <- LVar.empty
  flip runLoggerLoggingT logger $ do
    cwd <- liftIO getCurrentDirectory
    let logSrc = "main"
    logInfoNS logSrc $ "Launching Ema under: " <> toText cwd
    logInfoNS logSrc "Waiting for initial model ..."
    (model0 :: a, cont) <- runModelManager (siteModelManager site) (CLI.action cli) (siteRouteEncoder site)
    logInfoNS logSrc "... initial model is now available."
    case CLI.action cli of
      Some (CLI.Generate dest) -> do
        generateSite dest site model0
      Some (CLI.Run (host, port)) -> do
        LVar.set model model0
        liftIO $
          race_
            ( flip runLoggerLoggingT logger $ do
                cont model
                logWarnNS logSrc "modelPatcher exited; no more model updates."
                liftIO $ threadDelay maxBound
            )
            (flip runLoggerLoggingT logger $ Server.runServerWithWebSocketHotReload host port site model)
        pure [] -- FIXME: unreachable
