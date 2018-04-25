{-# LANGUAGE GADTs             #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedLists   #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module FastCut.Scene.View (renderScene) where

import           Data.Text             (Text)
import           Data.Time.Clock       (NominalDiffTime)

import           FastCut.Focus
import           FastCut.Scene
import           FastCut.Sequence
import           FastCut.VirtualWidget

sizeFromDuration :: (RealFrac d) => d -> Size
sizeFromDuration duration =
  let width = fromIntegral (ceiling duration :: Int) * 50 in Size width (-1)

focusedClass :: Focused -> Text
focusedClass = \case
  Focused             -> "focused"
  TransitivelyFocused -> "transitively-focused"
  Blurred             -> "blurred"

renderClip' :: Focused -> ClipMetadata -> Element
renderClip' focused metadata = Box
  boxProps { orientation = Horizontal
           , boxClasses  = ["clip", focusedClass focused]
           , size        = Just (sizeFromDuration (duration metadata))
           }
  [ BoxChild boxChildProps
             (Label labelProps { text = Just (clipName metadata) })
  ]

renderGap :: Focused -> NominalDiffTime -> Element
renderGap focused duration = Box
  boxProps { orientation = Horizontal
           , boxClasses  = ["gap", focusedClass focused]
           , size        = Just (sizeFromDuration duration)
           }
  [BoxChild boxChildProps (Label labelProps)]

renderClip :: Clip Focused t -> Element
renderClip = \case
  VideoClip focused metadata -> renderClip' focused metadata
  AudioClip focused metadata -> renderClip' focused metadata
  VideoGap  focused duration -> renderGap focused duration
  AudioGap  focused duration -> renderGap focused duration

renderSequence :: Sequence Focused -> Element
renderSequence = \case
  Sequence focused sub -> Box
    boxProps { orientation = Horizontal
             , boxClasses  = ["sequence", focusedClass focused]
             }
    (map (BoxChild boxChildProps . renderSequence) sub)
  Composition focused videoClips audioClips -> Box
    boxProps { orientation = Vertical
             , boxClasses  = ["composition", focusedClass focused]
             }
    [ BoxChild boxChildProps $ Box
      boxProps { orientation = Horizontal, boxClasses = ["video"] }
      (map (BoxChild boxChildProps . renderClip) videoClips)
    , BoxChild boxChildProps $ Box
      boxProps { orientation = Horizontal, boxClasses = ["audio"] }
      (map (BoxChild boxChildProps . renderClip) audioClips)
    ]
renderScene :: Scene -> Element
renderScene Scene {..} = Box
  boxProps { orientation = Vertical, boxClasses = ["scene"] }
  [ BoxChild boxChildProps { expand = True, fill = True } (Label labelProps { text = Just sceneName })
  , BoxChild boxChildProps (ScrollArea (renderSequence (applyFocus topSequence focus)))
  ]