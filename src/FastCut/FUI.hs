{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE KindSignatures         #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE OverloadedLabels       #-}
{-# LANGUAGE RankNTypes             #-}
{-# LANGUAGE RecordWildCards        #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE StandaloneDeriving     #-}
{-# LANGUAGE TypeApplications       #-}
{-# LANGUAGE TypeOperators          #-}

-- | The "functional user interface" module (FUI) represents a hierarchy of
-- immutable user interface objects, usually constructed in a pure setting, and
-- provides a patching mechanism for performing minimal updates using the
-- underlying imperative GTK library.
module FastCut.FUI where

import           Control.Monad           (forM_)
import           Data.Either             (partitionEithers)
import           Data.Foldable           (fold)
import qualified Data.GI.Base            as GI
import qualified Data.GI.Base.Attributes as GI
import           Data.HashSet            (HashSet)
import qualified Data.HashSet            as HashSet
import           Data.Int                (Int32)
import           Data.List               (zip4)
import           Data.Text               (Text)
import           Data.Typeable
import           Data.Word               (Word32)
import           GHC.TypeLits            (Symbol)
import qualified GI.Gtk                  as Gtk

data Patch
  = Modify (Gtk.Widget -> IO ())
  | Replace (IO Gtk.Widget)
  | Keep

class Patchable obj where
  create ::  obj -> IO Gtk.Widget
  patch :: obj -> obj -> Patch

data Object where
  Object :: (Eq o, Show o, Typeable o, Patchable o) => o -> Object

instance Patchable Object where
  create (Object obj) = create obj
  patch (Object (o1 :: t1)) (Object (o2 :: t2)) =
    case eqT @t1 @t2 of
      Just Refl -> patch o1 o2
      Nothing   -> Replace (create o2)

deriving instance Show Object

instance Eq Object where
  Object (a :: o) == Object (b :: n) =
    case eqT @o @n  of
      Just Refl -> a == b
      Nothing   -> False

-- * CSS

type ClassSet = HashSet Text

addClasses :: Gtk.IsWidget w => w -> ClassSet -> IO ()
addClasses widget cs = do
  sc <- Gtk.widgetGetStyleContext widget
  mapM_ (Gtk.styleContextAddClass sc) cs

replaceClasses :: Gtk.IsWidget w => w -> ClassSet -> ClassSet -> IO ()
replaceClasses widget old new = do
  sc <- Gtk.widgetGetStyleContext widget
  mapM_ (Gtk.styleContextRemoveClass sc) (HashSet.difference old new)
  mapM_ (Gtk.styleContextAddClass sc)    (HashSet.difference new old)

-- * Generic GTK patchable object

data AttrPair obj where
  (:=)
    :: (GI.AttrGetC info obj attr value
      , GI.AttrOpAllowed 'GI.AttrConstruct info obj
      , GI.AttrOpAllowed 'GI.AttrSet info obj
      , GI.AttrSetTypeConstraint info value
      , Typeable attr
      , Eq value
      )
    =>  GI.AttrLabelProxy (attr :: Symbol) -> value -> AttrPair obj
  Classes
    :: Gtk.IsWidget obj
    => ClassSet
    -> AttrPair obj

classes :: Gtk.IsWidget obj => [Text] -> AttrPair obj
classes = Classes . HashSet.fromList

instance Eq (AttrPair obj) where
  ((_ :: GI.AttrLabelProxy attr1) := v1) == ((_ :: GI.AttrLabelProxy attr2) := v2) =
    case eqT @attr1 @attr2 of
      Just Refl -> v1 == v2
      Nothing   -> False
  Classes c1 == Classes c2 = c1 == c2
  _ == _ = False

-- * Node (single object)

data GtkNode a where
  GtkNode :: (Typeable a, Gtk.IsWidget a) => (Gtk.ManagedPtr a -> a) -> [AttrPair a] -> GtkNode a

instance Eq (GtkNode a) where
  GtkNode _ a1 == GtkNode _ a2 =
    a1 == a2

instance Show (GtkNode a) where
  show = \case
    GtkNode{} -> "GtkNode"

instance Patchable (GtkNode a) where
  create = \case
    (GtkNode ctor attrs) -> do
        let (attrOps, classSets) = partitionEithers (map toOpOrClass attrs)
        widget <- Gtk.new ctor attrOps
        addClasses widget (fold classSets)
        Gtk.toWidget widget
    where
      toOpOrClass :: AttrPair obj -> Either (GI.AttrOp obj 'GI.AttrConstruct) ClassSet
      toOpOrClass =
        \case
          (attr := value) -> Left (attr Gtk.:= value)
          Classes c -> Right c
  patch (GtkNode _ oldAttrs) (GtkNode ctor newAttrs) = Modify $ \widget -> do
    let (_, oldClassSets) = partitionEithers (map toOpOrClass oldAttrs)
        (newAttrOps, newClassSets) = partitionEithers (map toOpOrClass newAttrs)
    w <- Gtk.unsafeCastTo ctor widget
    Gtk.set w newAttrOps
    replaceClasses w (fold oldClassSets) (fold newClassSets)
    Gtk.widgetShowAll w
    where
      toOpOrClass :: AttrPair obj -> Either (GI.AttrOp obj 'GI.AttrSet) ClassSet
      toOpOrClass =
        \case
          (attr := value) -> Left (attr Gtk.:= value)
          Classes c -> Right c

node :: (Typeable a, Gtk.IsWidget a) => (Gtk.ManagedPtr a -> a) -> [AttrPair a] -> Object
node ctor attrs = Object (GtkNode ctor attrs)

-- * Patchable Container

class PatchableContainer obj children where
  createChildrenIn :: obj -> children -> IO ()
  patchChildrenIn :: obj -> children -> children -> IO ()

-- * Box

padMaybes :: [a] -> [Maybe a]
padMaybes xs = map Just xs ++ repeat Nothing

replaceInBox :: (Gtk.Widget -> IO ()) -> Gtk.Box -> Int32 -> Gtk.Widget -> Gtk.Widget -> IO ()
replaceInBox append box i old new = do
  Gtk.containerRemove box old
  append new
  Gtk.boxReorderChild box new i

patchInBox
  :: Patchable child
  => (Gtk.Box -> child -> Gtk.Widget -> IO ())
  -> Gtk.Box
  -> [child]
  -> [child]
  -> IO ()
patchInBox appendChild box os' ns' = do
  cs <- Gtk.containerGetChildren box
  let maxLength = maximum [length cs, length os', length ns']
      indices = [0 .. pred (fromIntegral maxLength)]
  forM_ (zip4 indices (padMaybes cs) (padMaybes os') (padMaybes ns')) $ \case

    -- In case we have a corresponding old and new virtual widget, we patch the
    -- GTK widget.
    (i, Just w, Just old, Just new) ->
      case patch old new of
        Modify modify        -> modify w
        Replace createWidget ->
          replaceInBox (appendChild box new) box i w =<< createWidget
        Keep                 -> return ()

    -- When there is a new object, but there already exists a widget
    -- in the corresponding place, we need to replace the widget with
    -- one created from the object.
    (i, Just w, Nothing, Just new) ->
      replaceInBox (appendChild box new) box i w =<< create new

    -- When there is a new object, or one that lacks a corresponding GTK
    -- widget, create and add it.
    (_i, Nothing, _, Just n) ->
      create n >>= Gtk.containerAdd box

    -- When an object has been removed, remove the GTK widget from the
    -- container.
    (_i, Just w, Just _, Nothing) ->
      Gtk.containerRemove box w

    -- When there are more old objects than GTK widgets, we can safely
    -- ignore the old objects.
    (_i, Nothing, Just _, Nothing) -> return ()

    -- But, when there are stray GTK widgets without corresponding
    -- objects, something has gone wrong, and we clean that mess
    -- up by removing the GTK widgets.
    (_i, Just w, Nothing, Nothing) ->
      Gtk.containerRemove box w

    -- No more widgets or objects, we are done.
    (_i, Nothing, Nothing, Nothing) ->
      return ()

appendCreatedObjectInBox :: Gtk.Box -> Object -> Gtk.Widget -> IO ()
appendCreatedObjectInBox box _ = Gtk.containerAdd box

packCreatedBoxChildInBox :: Gtk.Box -> BoxChild -> Gtk.Widget -> IO ()
packCreatedBoxChildInBox box BoxChild{..} widget =
  Gtk.boxPackStart box widget expand fill padding

instance PatchableContainer Gtk.Box [Object] where
  createChildrenIn box = mapM_ $ \(Object child) ->
    appendCreatedObjectInBox box (Object child) =<< create child
  patchChildrenIn = patchInBox appendCreatedObjectInBox

data BoxChild = BoxChild { expand :: Bool, fill :: Bool, padding :: Word32, child :: Object }
  deriving (Eq, Show)

instance Patchable BoxChild where
  create = create . child
  patch b1 b2 = patch (child b1) (child b2)

instance PatchableContainer Gtk.Box [BoxChild] where
  createChildrenIn box = mapM_ $ \BoxChild {child = Object child, ..} -> do
    widget <- create child
    Gtk.boxPackStart box widget expand fill padding
  patchChildrenIn = patchInBox packCreatedBoxChildInBox

-- * ScrolledWindow

instance PatchableContainer Gtk.ScrolledWindow Object where
  createChildrenIn box (Object child) = create child >>= Gtk.containerAdd box
  patchChildrenIn scrolledWindow oldChild newChild = do
    viewport <- Gtk.containerGetChildren scrolledWindow
      >>= requireSingle "Viewport"
      >>= Gtk.unsafeCastTo Gtk.Viewport
    childWidget <- Gtk.containerGetChildren viewport
      >>= requireSingle "scrolled child"
    case patch oldChild newChild of
      Modify modify -> modify childWidget
      Replace createNew -> do
        Gtk.containerRemove viewport childWidget
        Gtk.containerAdd viewport =<< createNew
      Keep -> return ()
    where
      requireSingle what = \case
        [w] -> return w
        _ -> fail ("Expected a single " ++ what ++ " in the container.")

-- * Container object

data GtkContainer a children where
  GtkContainer
    :: (Typeable a, Gtk.IsWidget a, Eq children)
    => (Gtk.ManagedPtr a -> a)
    -> [AttrPair a]
    -> children
    -> GtkContainer a children

instance Eq (GtkContainer a children) where
  GtkContainer _ a1 c1 == GtkContainer _ a2 c2 =
    a1 == a2 && c1 == c2

instance Show (GtkContainer a children) where
  show = \case
    GtkContainer{} -> "GtkContainer"

instance PatchableContainer a children => Patchable (GtkContainer a children) where
  create (GtkContainer ctor attrs children) = do
    let (attrOps, classSets) = partitionEithers (map toOpOrClass attrs)
    widget <- Gtk.new ctor attrOps
    addClasses widget (fold classSets)
    createChildrenIn widget children
    Gtk.toWidget widget
    where
      toOpOrClass ::
           AttrPair obj -> Either (GI.AttrOp obj 'GI.AttrConstruct) ClassSet
      toOpOrClass =
        \case
          (attr := value) -> Left (attr Gtk.:= value)
          Classes c -> Right c
  patch (GtkContainer _ oldAttrs oldChildren) (GtkContainer ctor newAttrs newChildren) =
    Modify $ \widget -> do
      let (_, oldClassSets) = partitionEithers (map toOpOrClass oldAttrs)
          (newAttrOps, newClassSets) =
            partitionEithers (map toOpOrClass newAttrs)
      w <- Gtk.unsafeCastTo ctor widget
      Gtk.set w newAttrOps
      replaceClasses w (fold oldClassSets) (fold newClassSets)
      patchChildrenIn w oldChildren newChildren
    where
      toOpOrClass :: AttrPair obj -> Either (GI.AttrOp obj 'GI.AttrSet) ClassSet
      toOpOrClass =
        \case
          (attr := value) -> Left (attr Gtk.:= value)
          Classes c -> Right c

container ::
     ( Eq children
     , PatchableContainer a children
     , Typeable children
     , Typeable a
     , Gtk.IsWidget a
     )
  => (Gtk.ManagedPtr a -> a)
  -> [AttrPair a]
  -> children
  -> Object
container ctor attrs = Object . GtkContainer ctor attrs