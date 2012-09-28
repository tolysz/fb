{-# LANGUAGE FlexibleContexts #-}
module Facebook.TestUsers
    ( TestUser(..)
    , CreateTestUser(..)
    , CreateTestUserInstalled(..)
    , getTestUsers
    , removeTestUser
    , createTestUser
    , makeFriendConn
    , incompleteTestUserAccessToken
    ) where


import Control.Monad (unless, mzero)
import Control.Applicative ((<$>), (<*>))
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.Default
import Data.Text
import Data.Typeable (Typeable)
import Data.Time (UTCTime(..), Day(..))


import qualified Control.Exception.Lifted as E
import qualified Data.ByteString.Char8 as B
import qualified Data.Conduit as C
import qualified Data.Aeson as A


import Facebook.Auth
import Facebook.Graph
import Facebook.Types
import Facebook.Monad
import Facebook.Base


-- | A Facebook test user
data TestUser =
    TestUser { tuId          :: UserId
             , tuAccessToken :: Maybe AccessTokenData
             , tuLoginUrl    :: Maybe Text
             , tuEmail       :: Maybe Text
             , tuPassword    :: Maybe Text
             }
    deriving (Eq, Ord, Show, Read, Typeable)


instance A.FromJSON TestUser where
    parseJSON (A.Object v) =
        TestUser <$> v A..: "id"
                 <*> v A..:? "access_token"
                 <*> v A..:? "login_url"
                 <*> v A..:? "email"
                 <*> v A..:? "password"
    parseJSON _ = mzero



-- | Data type to hold information of a new test user.
data CreateTestUser =
 CreateTestUser
   { ctuInstalled :: CreateTestUserInstalled
   , ctuName      :: Maybe Text
   , ctuLocale    :: Maybe Text
   }


-- | Specify if the app will be installed on the new test user.
-- If it is, then you must tell what permissions should be given.
data CreateTestUserInstalled =
   CreateTestUserNotInstalled
 | CreateTestUserInstalled { ctuiPermissions :: [Permission] }
 | CreateTestUserFbDefault
   -- ^ Uses Facebook's default. It seems that this is equivalent to
   -- @CreateTestUserInstalled []@, but Facebook's documentation is
   -- not clear about it.


instance Default CreateTestUser where
    def = CreateTestUser def def def


instance Default CreateTestUserInstalled where
    def = CreateTestUserFbDefault


-- | Construct a query from a 'CreateTestUser'
createTestUserQueryArgs :: CreateTestUser -> [Argument]
createTestUserQueryArgs (CreateTestUser installed name locale) =
    forInst installed ++ forField "name" name ++ forField "locale" locale
    where
      forInst (CreateTestUserInstalled p) = [ "installed" #= True, "permissions" #= p ]
      forInst CreateTestUserNotInstalled  = [ "installed" #= False ]
      forInst CreateTestUserFbDefault     = []
      forField _ Nothing          = []
      forField fieldName (Just f) = [ fieldName #= f ]


-- | Create a new test user.
createTestUser :: (C.MonadResource m, MonadBaseControl IO m)
                  => CreateTestUser -- ^ New user information
                                    -- encapsulated on
                                    -- 'CreateTestUser'
                  -> AppAccessToken -- ^ Access token for your app.
                  -> FacebookT Auth m TestUser
createTestUser userInfo token = do
  creds <- getCreds
  let query = ("method","post") : createTestUserQueryArgs userInfo
  getObject ("/" <> appId creds <> "/accounts/test-users") query (Just token)


-- | Get a list of test users.
getTestUsers :: (C.MonadResource m, MonadBaseControl IO m)
                => AppAccessToken      -- ^ Access token for your app.
                -> FacebookT Auth m (Pager TestUser)
getTestUsers token = do
  creds <- getCreds
  getObject ("/" <> appId creds <> "/accounts/test-users") [] (Just token)


-- | Remove an existing test user.
removeTestUser :: (C.MonadResource m, MonadBaseControl IO m)
                  => TestUser              -- ^ The TestUser to be removed
                  -> AppAccessToken -- ^ Access token for your app.
                  -> FacebookT Auth m Bool
removeTestUser testUser token =
  getObjectBool ("/" <> tuId testUser) [("method","delete")] (Just token)


-- | Make a friend connection between two test users. Two calls must
-- be made. Let's imagine a scenario where we have two test users: A
-- and B. The first call has the format:
-- \"\/userA_id\/friends\/userB_id\" with the access token of user A
-- as query parameter. The second call has the format:
-- \"\/userB_id\/friends\/userA_id\" with the access token of user B
-- as query parameter. The first call creates a friend request and the
-- second call confirms the friend request.
makeFriendConn :: (C.MonadResource m, MonadBaseControl IO m)
                  => TestUser
                  -> TestUser
                  -> FacebookT Auth m ()
makeFriendConn (TestUser { tuAccessToken = Nothing }) _ = E.throw $
  FbLibraryException "You must specify both users' access tokens."
makeFriendConn _ (TestUser { tuAccessToken = Nothing }) = E.throw $
  FbLibraryException "You must specify both users' access tokens."
makeFriendConn (TestUser {tuId = id1, tuAccessToken = (Just token1)})
               (TestUser {tuId = id2, tuAccessToken = (Just token2)}) = do
  result1 <- getObjectBool
                ("/" <> id1 <> "/friends/" <> id2)
                [ "method" #= ("post" :: B.ByteString), "access_token" #= token1 ]
                Nothing
  result2 <- getObjectBool
                ("/" <> id2 <> "/friends/" <> id1)
                [ "method" #= ("post" :: B.ByteString), "access_token" #= token2 ]
                Nothing
  unless result1 $ E.throw $ FbLibraryException "Couldn't make friend request."
  unless result2 $ E.throw $ FbLibraryException "Couldn't confirm friend request."
  return ()


-- | Create an 'UserAccessToken' from a 'TestUser'.  It's incomplete
-- because it will not have the right expiration time.
incompleteTestUserAccessToken :: TestUser -> Maybe UserAccessToken
incompleteTestUserAccessToken t = do
  tokenData <- tuAccessToken t
  let farFuture = UTCTime (ModifiedJulianDay 100000) 0
  return (UserAccessToken (tuId t) tokenData farFuture)


-- | Same as 'getObject', but instead of parsing the result
-- as a JSON, it tries to parse either as "true" or "false".
-- Used only by the Test User API bindings.
getObjectBool :: (C.MonadResource m, MonadBaseControl IO m)
                 => B.ByteString                -- ^ Path (should
                                                -- begin with a slash
                                                -- @\/@)
                 -> [Argument]                  -- ^ Arguments to be
                                                -- passed to Facebook
                 -> Maybe (AccessToken anyKind) -- ^ Optional access
                                                -- token
                 -> FacebookT anyAuth m Bool
getObjectBool path query mtoken =
 runResourceInFb $ do
   bs <- asBS =<< fbhttp =<< fbreq path mtoken query
   return (bs == "true")
