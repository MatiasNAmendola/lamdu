{-# LANGUAGE OverloadedStrings #-}
module Editor.CodeEdit.ExpressionEdit(make) where

import Control.Arrow (first, second)
import Control.Monad (liftM, liftM2)
import Data.ByteString.Char8 (pack)
import Data.Monoid (Monoid(..))
import Data.Store.IRef (IRef)
import Data.Store.Transaction (Transaction)
import Editor.Anchors (ViewTag)
import Editor.CTransaction (TWidget, getP, transaction, subCursor)
import Editor.CodeEdit.Types(AncestryItem(..), ApplyParent(..), LambdaParent(..), ApplyRole(..))
import Editor.MonadF (MonadF)
import qualified Data.Store.Property as Property
import qualified Data.Store.Transaction as Transaction
import qualified Editor.Anchors as Anchors
import qualified Editor.BottleWidgets as BWidgets
import qualified Editor.CodeEdit.ExpressionEdit.ApplyEdit as ApplyEdit
import qualified Editor.CodeEdit.ExpressionEdit.HoleEdit as HoleEdit
import qualified Editor.CodeEdit.ExpressionEdit.LambdaEdit as LambdaEdit
import qualified Editor.CodeEdit.ExpressionEdit.LiteralEdit as LiteralEdit
import qualified Editor.CodeEdit.ExpressionEdit.VarEdit as VarEdit
import qualified Editor.CodeEdit.Types as ETypes
import qualified Editor.Config as Config
import qualified Editor.Data as Data
import qualified Editor.DataOps as DataOps
import qualified Editor.WidgetIds as WidgetIds
import qualified Graphics.UI.Bottle.Widget as Widget
import qualified Graphics.UI.Bottle.Widgets.FocusDelegator as FocusDelegator

data HoleResultPicker m = NotAHole | IsAHole (Maybe (HoleEdit.ResultPicker m))

data HighlightParens = DoHighlightParens | DontHighlightParens

makeParensId
  :: Monad m => ETypes.ExpressionAncestry m
  -> Transaction ViewTag m Widget.Id
makeParensId (AncestryItemApply (ApplyParent role _ _ parentPtr) : _) = do
  parentI <- Property.get parentPtr
  return $
    Widget.joinId (WidgetIds.fromIRef parentI)
    [pack $ show role]
makeParensId (AncestryItemLambda (LambdaParent _ parentPtr) : _) =
  liftM WidgetIds.fromIRef $ Property.get parentPtr
makeParensId [] =
  return $ Widget.Id ["root parens"]

makeCondParensId
  :: Monad m
  => Bool -> ETypes.ExpressionAncestry m
  -> Transaction ViewTag m (Maybe Widget.Id)
makeCondParensId False = const $ return Nothing
makeCondParensId True = liftM Just . makeParensId

setDoHighlight :: (Monad m, Functor f) => m (f a) -> m (f (HighlightParens, a))
setDoHighlight = (liftM . fmap) ((,) DoHighlightParens)

setDontHighlight :: (Monad m, Functor f) => m (f a) -> m (f (HighlightParens, a))
setDontHighlight = (liftM . fmap) ((,) DontHighlightParens)

getParensInfo
  :: Monad m
  => Data.Expression -> ETypes.ExpressionAncestry m
  -> Transaction ViewTag m (Maybe (HighlightParens, Widget.Id))
getParensInfo (Data.ExpressionApply _) ancestry@(AncestryItemApply (ApplyParent ApplyArg ETypes.Prefix _ _) : _) =
  setDoHighlight . liftM Just $ makeParensId ancestry
getParensInfo (Data.ExpressionApply (Data.Apply funcI _)) ancestry@(AncestryItemApply (ApplyParent ApplyArg _ _ _) : _) = do
  isInfix <-
    liftM2 (||)
    (ETypes.isInfixFunc funcI) (ETypes.isApplyOfInfixOp funcI)
  setDoHighlight $ makeCondParensId isInfix ancestry
getParensInfo (Data.ExpressionApply (Data.Apply funcI _)) ancestry@(AncestryItemApply (ApplyParent ApplyFunc _ _ _) : _) = do
  isInfix <- ETypes.isApplyOfInfixOp funcI
  setDoHighlight $ makeCondParensId isInfix ancestry
getParensInfo (Data.ExpressionApply (Data.Apply funcI _)) ancestry = do
  isInfix <- ETypes.isInfixFunc funcI
  setDoHighlight $ makeCondParensId isInfix ancestry
getParensInfo (Data.ExpressionGetVariable _) (AncestryItemApply (ApplyParent ApplyFunc _ _ _) : _) =
  return Nothing
getParensInfo (Data.ExpressionGetVariable var) ancestry = do
  name <- Property.get $ Anchors.variableNameRef var
  setDontHighlight $ makeCondParensId (ETypes.isInfixName name) ancestry
getParensInfo (Data.ExpressionLambda _) ancestry@(AncestryItemApply _ : _) =
  setDoHighlight $ liftM Just $ makeParensId ancestry
getParensInfo _ _ = return Nothing

make
  :: MonadF m
  => ETypes.ExpressionAncestry m -> IRef Data.Definition
  -> ETypes.ExpressionPtr m -> TWidget ViewTag m
make ancestry definitionI expressionPtr = do
  expressionI <- getP expressionPtr
  expr <- getP $ Transaction.fromIRef expressionI
  let
    notAHole = (fmap . liftM) ((,) NotAHole)
    wrapNonHole keys isDelegating f =
      notAHole . BWidgets.wrapDelegatedWithKeys keys isDelegating f
    makeExpression = (`make` definitionI)
    makeEditor =
      case expr of
        Data.ExpressionHole holeState ->
          (fmap . liftM . first) IsAHole .
          BWidgets.wrapDelegatedWithKeys
            FocusDelegator.defaultKeys FocusDelegator.Delegating second $
            HoleEdit.make ancestry definitionI holeState expressionPtr
        Data.ExpressionGetVariable varRef -> notAHole (VarEdit.make varRef)
        Data.ExpressionLambda lambda ->
          wrapNonHole Config.exprFocusDelegatorKeys
            FocusDelegator.Delegating id $
          LambdaEdit.make makeExpression ancestry expressionPtr lambda
        Data.ExpressionApply apply ->
          wrapNonHole Config.exprFocusDelegatorKeys
            FocusDelegator.Delegating id $
          ApplyEdit.make makeExpression ancestry expressionPtr apply
        Data.ExpressionLiteralInteger integer ->
          wrapNonHole FocusDelegator.defaultKeys
            FocusDelegator.NotDelegating id $
          LiteralEdit.makeInt expressionI integer
  let expressionId = WidgetIds.fromIRef expressionI
  (holePicker, widget) <- makeEditor expressionId
  (addArgDoc, addArgHandler) <-
    transaction $ ETypes.makeAddArgHandler ancestry expressionPtr
  let
    eventMap = mconcat
      [ moveUnlessOnHole .
        Widget.actionEventMapMovesCursor
        Config.giveAsArgumentKeys "Give as argument" .
        ETypes.diveIn $ DataOps.giveAsArg expressionPtr
      , moveUnlessOnHole .
        Widget.actionEventMapMovesCursor
        Config.callWithArgumentKeys "Call with argument" .
        ETypes.diveIn $ DataOps.callWithArg expressionPtr
      , pickResultFirst $
        Widget.actionEventMapMovesCursor
        Config.addNextArgumentKeys addArgDoc addArgHandler
      , ifHole (const mempty) $
        Widget.actionEventMapMovesCursor
        relinkKeys "Replace" . ETypes.diveIn $
        DataOps.replace expressionPtr
      , Widget.actionEventMapMovesCursor
        Config.lambdaWrapKeys "Lambda wrap" . ETypes.diveIn $
        DataOps.lambdaWrap expressionPtr
      ]
    relinkKeys
      | null ancestry = Config.relinkKeys ++ Config.delKeys
      | otherwise = Config.relinkKeys
    ifHole f =
      case holePicker of
        NotAHole -> id
        IsAHole x -> f x
    moveUnlessOnHole = ifHole $ (const . fmap . liftM . Widget.atECursor . const) Nothing
    pickResultFirst = ifHole (maybe id (fmap . joinEvents))
    joinEvents x y = do
      r <- liftM Widget.eAnimIdMapping x
      (liftM . Widget.atEAnimIdMapping) (. r) y

  mParenInfo <- transaction $ getParensInfo expr ancestry
  addParens expressionId mParenInfo $ Widget.weakerEvents eventMap widget

highlightExpression :: Widget.Widget f -> Widget.Widget f
highlightExpression =
  Widget.backgroundColor WidgetIds.parenHighlightId Config.parenHighlightColor

addParens
  :: (Monad m, Functor m)
  => Widget.Id
  -> Maybe (HighlightParens, Widget.Id)
  -> Widget.Widget (Transaction t m)
  -> TWidget t m
addParens _ Nothing widget = return widget
addParens myId (Just (needHighlight, parensId)) widget = do
  mInsideParenId <- subCursor rParenId
  widgetWithParens <- ETypes.addParens id doHighlight parensId widget
  return $ maybe id (const highlightExpression) mInsideParenId widgetWithParens
  where
    rParenId = Widget.joinId myId [")"]
    doHighlight =
      case needHighlight of
        DoHighlightParens -> (>>= BWidgets.makeFocusableView rParenId)
        DontHighlightParens -> id