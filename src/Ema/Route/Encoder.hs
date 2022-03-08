{-# LANGUAGE InstanceSigs #-}

module Ema.Route.Encoder
  ( -- * Route encoder
    RouteEncoder,
    IsRoute (RouteModel, mkRouteEncoder),
    unsafeMkRouteEncoder,
    encodeRoute,
    decodeRoute,
    allRoutes,
    defaultEnum,
    singletonRouteEncoder,
    singletonRouteEncoderFrom,
    mapRouteEncoder,
    leftRouteEncoder,
    rightRouteEncoder,
    Mergeable (merge),

    -- * Internal
    checkRouteEncoderForSingleRoute,
    -- PartialIsoFunctor (pimap),
  )
where

import Control.Lens (Iso)
import Control.Lens qualified as Lens
import Control.Monad.Writer
import Data.Aeson (FromJSON (parseJSON), Value)
import Data.Aeson.Types (Parser)
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Network.URI.Slug qualified as Slug

-- | An Iso that is not necessarily surjective; as well as takes an (unchanging)
-- context value.
--
-- Parse `s` into (optional) `a` which can always be converted to a `s`. The `a`
-- can be enumerated finitely. `ctx` is used to all functions.
-- TODO: Is this isomrophic to `Iso (ctx, a) (Maybe a) s (ctx, s)` (plus, `ctx -> [a]`)?
-- TODO: replace `ctx` arg with Reader monad?
newtype PartialIsoEnumerableWithCtx ctx s a
  = PartialIsoEnumerableWithCtx (ctx -> a -> s, ctx -> s -> Maybe a, ctx -> [a])

-- | A partial Iso between `s` and `a`, with finite `a` values - and with access
-- to some context `x`.
newtype PIso x s a
  = PIso
      ( -- Encoder
        a -> Reader x s,
        -- Decoder
        s -> ReaderT x Maybe a,
        -- Universe
        Reader x [a]
      )

piencode :: PIso r s a -> r -> a -> s
piencode (PIso (f, _, _)) x =
  flip runReader x . f

pidecode :: PIso r s a -> r -> s -> Maybe a
pidecode (PIso (_, f, _)) x =
  flip runReaderT x . f

piuniverse :: PIso r s a -> r -> [a]
piuniverse (PIso (_, _, f)) = runReader f

pimap' ::
  Iso s1 (Maybe s1) s2 s2 ->
  Iso a1 a1 (Maybe a2) a2 ->
  (r2 -> r1) ->
  PIso r1 s1 a1 ->
  PIso r2 s2 a2
pimap' sIso aIso rf (PIso (enc, dec, univ)) =
  PIso (enc', dec', univ')
  where
    enc' a = withReader rf $ do
      let a' = isoLeft aIso a
      s' <- enc a'
      pure $ isoRight sIso s'
    dec' s = withReaderT rf $ do
      s' <- lift $ isoLeft sIso s
      a <- dec s'
      lift $ isoRight aIso a
    univ' = withReader rf $ do
      mapMaybe (isoRight aIso) <$> univ
    isoRight iso x = Lens.withIso iso $ \f _ -> f x
    isoLeft iso x = Lens.withIso iso $ \_ f -> f x

{-
type T ctx a s = CtxIso ctx a (Maybe a) s s

type CtxIso ctx a b c d = Iso (ctx, a) b c (ctx, d)

type T' ctx a = ctx -> [a]
-}

partialIsoIsLawfulFor :: (Eq a, Eq s, Show a, ToText s) => PartialIsoEnumerableWithCtx ctx s a -> ctx -> a -> s -> Writer [Text] Bool
partialIsoIsLawfulFor (PartialIsoEnumerableWithCtx (to, from, _)) ctx a s = do
  tell . one $ "Testing Partial ISO law for " <> show a <> " and " <> toText s
  let s' = to ctx a
  tell . one $ "Route's actual encoding: " <> toText s'
  let ma' = from ctx s'
  tell . one $ "Decoding of that encoding: " <> show ma'
  unless (s == s') $
    tell . one $ "ERR: " <> toText s <> " /= " <> toText s'
  unless (Just a == ma') $
    tell . one $ "ERR: " <> show (Just a) <> " /= " <> show ma'
  pure $ (s == s') && (Just a == ma')

class PartialIsoFunctor (f :: Type -> Type -> Type -> Type) where
  pimap ::
    Iso a (Maybe a) b b ->
    Iso c c (Maybe d) d ->
    (y -> x) ->
    f x a c ->
    f y b d

instance PartialIsoFunctor PartialIsoEnumerableWithCtx where
  pimap ::
    forall a b c d x y.
    Iso a (Maybe a) b b ->
    Iso c c (Maybe d) d ->
    (y -> x) ->
    PartialIsoEnumerableWithCtx x a c ->
    PartialIsoEnumerableWithCtx y b d
  pimap iso1 iso2 h (PartialIsoEnumerableWithCtx (enc, dec, all_)) =
    PartialIsoEnumerableWithCtx (enc', dec', all_')
    where
      enc' :: y -> d -> b
      enc' m r =
        let r' :: c = Lens.withIso iso2 $ \_ f -> f r
            m' :: x = h m
         in Lens.withIso iso1 $ \f _ -> f $ enc m' r'
      dec' :: y -> b -> Maybe d
      dec' m fp = do
        fp' <- Lens.withIso iso1 $ \_ f -> f fp
        r :: c <- dec (h m) fp'
        Lens.withIso iso2 $ \f _ -> f r
      all_' :: y -> [d]
      all_' m =
        mapMaybe (\x -> Lens.withIso iso2 $ \f _ -> f x) (all_ $ h m)

newtype RouteEncoder a r = RouteEncoder (PartialIsoEnumerableWithCtx a FilePath r)

mapRouteEncoder ::
  Iso FilePath (Maybe FilePath) FilePath FilePath ->
  Iso r1 r1 (Maybe r2) r2 ->
  (b -> a) ->
  RouteEncoder a r1 ->
  RouteEncoder b r2
mapRouteEncoder fpIso rIso mf (RouteEncoder enc) =
  RouteEncoder $ pimap fpIso rIso mf enc

unsafeMkRouteEncoder :: (ctx -> a -> FilePath) -> (ctx -> FilePath -> Maybe a) -> (ctx -> [a]) -> RouteEncoder ctx a
unsafeMkRouteEncoder x y z = RouteEncoder $ PartialIsoEnumerableWithCtx (x, y, z)

encodeRoute :: RouteEncoder model r -> model -> r -> FilePath
encodeRoute (RouteEncoder (PartialIsoEnumerableWithCtx (f, _, _))) = f

decodeRoute :: RouteEncoder model r -> model -> FilePath -> Maybe r
decodeRoute (RouteEncoder (PartialIsoEnumerableWithCtx (_, f, _))) = f

allRoutes :: RouteEncoder model r -> model -> [r]
allRoutes (RouteEncoder (PartialIsoEnumerableWithCtx (_, _, f))) = f

-- | Route encoder for single route encoding to 'index.html'
singletonRouteEncoder :: RouteEncoder a ()
singletonRouteEncoder =
  singletonRouteEncoderFrom "index.html"

instance IsRoute () where
  type RouteModel () = ()
  mkRouteEncoder = singletonRouteEncoder

-- | Class of product-cum-sum indexed types that can be merged.
class Mergeable (f :: Type -> Type -> Type) where
  -- | Merge by treating the first index as product, and second as sum.
  merge :: f a b -> f c d -> f (a, c) (Either b d)

instance Mergeable RouteEncoder where merge = mergeRouteEncoder

-- | Returns a new route encoder that supports either of the input routes.
mergeRouteEncoder :: RouteEncoder a r1 -> RouteEncoder b r2 -> RouteEncoder (a, b) (Either r1 r2)
mergeRouteEncoder enc1 enc2 =
  unsafeMkRouteEncoder
    ( \m ->
        either
          (encodeRoute enc1 (fst m))
          (encodeRoute enc2 (snd m))
    )
    ( \m fp ->
        asum
          [ Left <$> decodeRoute enc1 (fst m) fp,
            Right <$> decodeRoute enc2 (snd m) fp
          ]
    )
    ( \m ->
        mconcat
          [ Left <$> allRoutes enc1 (fst m),
            Right <$> allRoutes enc2 (snd m)
          ]
    )

-- | TODO: Can do this using generics, on any `f` (not just Either)
--
-- But we as well need model lens for each inner route. Unless we use heterogenous list?
leftRouteEncoder :: RouteEncoder (a, b) (Either r1 r2) -> RouteEncoder a r1
leftRouteEncoder =
  mapRouteEncoder
    (Lens.iso id Just)
    (Lens.iso leftToMaybe Left)
    (,undefined)

rightRouteEncoder :: RouteEncoder (a, b) (Either r1 r2) -> RouteEncoder b r2
rightRouteEncoder =
  mapRouteEncoder
    (Lens.iso id Just)
    (Lens.iso rightToMaybe Right)
    (undefined,)

singletonRouteEncoderFrom :: FilePath -> RouteEncoder a ()
singletonRouteEncoderFrom fp =
  unsafeMkRouteEncoder (const enc) (const dec) (const all_)
  where
    enc () = fp
    dec fp' = guard (fp' == fp)
    all_ = [()]

-- TODO: Determine this generically somehow
-- See https://github.com/srid/ema/issues/76
defaultEnum :: (Bounded r, Enum r) => [r]
defaultEnum = [minBound .. maxBound]

checkRouteEncoderForSingleRoute :: (Eq route, Show route) => RouteEncoder model route -> model -> route -> FilePath -> Writer [Text] Bool
checkRouteEncoderForSingleRoute (RouteEncoder piso) = partialIsoIsLawfulFor piso

class IsRoute r where
  type RouteModel r :: Type
  mkRouteEncoder :: RouteEncoder (RouteModel r) r