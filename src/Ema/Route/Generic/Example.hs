{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE UndecidableInstances #-}

module Ema.Route.Generic.Example where

import Data.Generics.Sum.Any (AsAny (_As))
import Data.SOP (I (..), NP (..))
import Ema.App qualified as Ema
import Ema.Asset qualified as Asset
import Ema.Route.Class (IsRoute (..))
import Ema.Route.Encoder
import Ema.Route.Generic (WithConstModel (..), WithModel (..))
import Ema.Route.Generic.Sub
import Ema.Site
import Generics.SOP qualified as SOP
import Optics.Prism (prism')

-- ----------
-- Examples
-- ----------

type M = (Int, Int, String)

data R = R_Index | R_Foo | R_Bar NumRoute | R_Bar2 NumRoute
  deriving stock (Show, Eq, Generic)
  deriving anyclass (SOP.Generic, SOP.HasDatatypeInfo, HasSubRoutes)
  deriving (IsRoute) via (WithModel R M) -- This only works if SubModels R ~ M

-- ^ HasSubRoutes instance generates:

{-
instance HasSubRoutes R where
  type
    SubRoutes R =
      '[ FileRoute "index.html"
       , FileRoute "foo.html"
       , FolderRoute "bar" NumRoute
       , FolderRoute "bar2" NumRoute
       ]
-}

data NumRoute = NumRoute
  deriving stock (Show, Eq)

instance IsRoute NumRoute where
  type RouteModel NumRoute = Int
  routeEncoder = mkRouteEncoder $ \n ->
    let fp = show n <> ".html"
     in prism' (const fp) $ \s -> do
          guard $ s == fp
          pure NumRoute
  allRoutes _ = [NumRoute]

-- TODO: In many simple cases (such as single model cases) this can be derived
-- generically. But allow the user to define this manually if need be. Also cf.
-- Sub-type. https://hackage.haskell.org/package/records-sop-0.1.1.0/docs/Generics-SOP-Record-SubTyping.html
instance HasSubModels R where
  subModels (a, b, _) =
    I a :* I b :* Nil

instance EmaSite R where
  siteInput _ () = pure $ pure (42, 21, "inner")
  siteOutput _ m r = Asset.AssetGenerated Asset.Html $ show r <> show m

-- --warnings -c "cabal repl ema -f with-examples" -T Ema.Route.Generic.main  --setup ":set args gen /tmp"
main :: IO ()
main = Ema.runSite_ @R ()

-- ---
-- Let's try defining a top-level route using `R` to see how EmaSite instances compose.
-- --

type TM = (M, String)

data TR = TR_Index | TR_Inner R
  deriving stock (Show, Eq, Generic)
  deriving anyclass (SOP.Generic, SOP.HasDatatypeInfo, HasSubRoutes)
  deriving (IsRoute) via (WithModel TR TM) -- This only works if SubModels R ~ M

instance HasSubModels TR where
  subModels (m, _) =
    I m :* Nil

instance EmaSite TR where
  siteInput x () = do
    m1 <- siteInput @R x ()
    pure $ fmap (,"TOP") m1
  siteOutput enc m = \case
    r@TR_Index ->
      Asset.AssetGenerated Asset.Html $ show r <> show m
    TR_Inner r ->
      -- Might as well provide a `innerSiteOutput (_As @TR_Inner)`?
      siteOutput @R (trInnerEnc enc) (trInnerModel m) r

-- TODO: General version of this (cf. innerRouteEncoder)
trInnerEnc enc =
  enc
    & mapRouteEncoderRoute (_As @"TR_Inner")
    & mapRouteEncoderModel (,undefined) -- See #94

-- TODO: General version of this (cf. innerModel)
trInnerModel m =
  let I m' :* Nil = subModels @TR m
   in m'

mainTop :: IO ()
mainTop = Ema.runSite_ @TR ()

-- ---
-- Ensure that the constant model case (simple one) still works
-- --

type M2 = (Int, String)

data R2 = R2_Index | R2_Foo | R2_Bar BarRoute | R2_Bar2 BarRoute
  deriving stock (Show, Eq, Generic)
  deriving anyclass (SOP.Generic, SOP.HasDatatypeInfo, HasSubRoutes)
  deriving (IsRoute, HasSubModels) via (WithConstModel R2 M2)

data BarRoute = BarRoute
  deriving stock (Show, Eq, Generic)
  deriving anyclass (SOP.Generic, SOP.HasDatatypeInfo, HasSubRoutes)
  deriving (IsRoute, HasSubModels) via (WithConstModel BarRoute M2)

instance EmaSite R2 where
  siteInput _ () = pure $ pure (21, "inner")
  siteOutput _ m r = Asset.AssetGenerated Asset.Html $ show r <> show m

mainConst :: IO ()
mainConst = Ema.runSite_ @R2 ()