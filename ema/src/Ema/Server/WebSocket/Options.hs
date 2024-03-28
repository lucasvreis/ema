{-# LANGUAGE QuasiQuotes #-}

module Ema.Server.WebSocket.Options where

import Colog (logDebug)
import Data.Default (Default (def))
import Ema.CLI (AppM)
import Ema.Route.Class (IsRoute (RouteModel))
import Ema.Server.Common (wsClientJSShim)
import NeatInterpolation (text)
import Network.WebSockets qualified as WS

{- | A handler takes a websocket connection and the current model and then watches
   for websocket messages. It must return a new route to watch (after that, the
   returned route's HTML will be sent back to the client).

  Note that this is usually a long-running thread that waits for the client's
  messages. But you can also use it to implement custom server actions, by handling
  the incoming websocket messages or other IO events in any way you like.

  Also note that whenever the model is updated, the handler action will be
  stopped and then restarted with the new model as argument.
-}
newtype EmaWsHandler r = EmaWsHandler
  { unEmaWsHandler :: (HasCallStack) => WS.Connection -> RouteModel r -> AppM Text
  }

instance Default (EmaWsHandler r) where
  def = EmaWsHandler $ \conn _model -> do
    msg :: Text <- liftIO $ WS.receiveData conn
    logDebug $ "<~~ " <> show msg
    pure msg

data EmaWebSocketOptions r = EmaWebSocketOptions
  { emaWebSocketClientShim :: LByteString
  , emaWebSocketServerHandler :: EmaWsHandler r
  }

instance Default (EmaWebSocketOptions r) where
  def =
    EmaWebSocketOptions wsClientJS def

-- Browser-side JavaScript code for interacting with the Haskell server
wsClientJS :: LByteString
wsClientJS =
  encodeUtf8
    [text|
        <script type="module" src="https://cdn.jsdelivr.net/npm/morphdom@2.7.2/dist/morphdom-umd.min.js"></script>

        <script type="module">
        ${wsClientJSShim}
        
        window.onpageshow = function () { init(false) };
        </script>
    |]
