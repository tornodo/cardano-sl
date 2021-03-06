{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Wallet.WalletLayer.Kernel
    ( bracketPassiveWallet
    , bracketActiveWallet
    ) where

import           Universum

import           Data.Coerce (coerce)
import           Data.Default (def)
import           Data.Maybe (fromJust)
import           Data.Time.Units (Second)
import           System.Wlog (Severity (Debug))

import           Pos.Block.Types (Blund, Undo (..))

import qualified Cardano.Wallet.Kernel as Kernel
import qualified Cardano.Wallet.Kernel.Addresses as Kernel
import qualified Cardano.Wallet.Kernel.DB.HdWallet as HD
import           Cardano.Wallet.Kernel.DB.InDb (InDb (..))
import           Cardano.Wallet.Kernel.DB.Resolved (ResolvedBlock)
import           Cardano.Wallet.Kernel.Diffusion (WalletDiffusion (..))
import           Cardano.Wallet.Kernel.Keystore (Keystore)
import           Cardano.Wallet.Kernel.Types (AccountId (..),
                     RawResolvedBlock (..), fromRawResolvedBlock)
import           Cardano.Wallet.WalletLayer.ExecutionTimeLimit
                     (limitExecutionTimeTo)
import           Cardano.Wallet.WalletLayer.Types (ActiveWalletLayer (..),
                     CreateAddressError (..), PassiveWalletLayer (..))

import           Pos.Core (decodeTextAddress)
import           Pos.Core.Chrono (OldestFirst (..))
import           Pos.Crypto (safeDeterministicKeyGen)
import           Pos.Util.Mnemonic (Mnemonic, mnemonicToSeed)

import qualified Cardano.Wallet.API.V1.Types as V1
import qualified Cardano.Wallet.Kernel.Actions as Actions
import qualified Data.Map.Strict as Map
import           Pos.Crypto.Signing

-- | Initialize the passive wallet.
-- The passive wallet cannot send new transactions.
bracketPassiveWallet
    :: forall m n a. (MonadIO n, MonadIO m, MonadMask m)
    => (Severity -> Text -> IO ())
    -> Keystore
    -> (PassiveWalletLayer n -> Kernel.PassiveWallet -> m a) -> m a
bracketPassiveWallet logFunction keystore f =
    Kernel.bracketPassiveWallet logFunction keystore $ \w -> do

      -- Create the wallet worker and its communication endpoint `invoke`.
      bracket (liftIO $ Actions.forkWalletWorker $ Actions.WalletActionInterp
                 { Actions.applyBlocks  =  \blunds ->
                     Kernel.applyBlocks w $
                         OldestFirst (mapMaybe blundToResolvedBlock (toList (getOldestFirst blunds)))
                 , Actions.switchToFork = \_ _ -> logFunction Debug "<switchToFork>"
                 , Actions.emit         = logFunction Debug
                 }
              ) (\invoke -> liftIO (invoke Actions.Shutdown))
              $ \invoke -> do
                  -- TODO (temporary): build a sample wallet from a backup phrase
                  _ <- liftIO $ do
                    let (_, esk) = safeDeterministicKeyGen (mnemonicToSeed $ def @(Mnemonic 12)) emptyPassphrase
                    Kernel.createWalletHdRnd w walletName spendingPassword assuranceLevel esk Map.empty

                  f (passiveWalletLayer w invoke) w

  where
    -- TODO consider defaults
    walletName       = HD.WalletName "(new wallet)"
    spendingPassword = HD.NoSpendingPassword
    assuranceLevel   = HD.AssuranceLevelNormal

    -- | TODO(ks): Currently not implemented!
    passiveWalletLayer :: Kernel.PassiveWallet
                       -> (Actions.WalletAction Blund -> IO ())
                       -> PassiveWalletLayer n
    passiveWalletLayer wallet invoke =
        PassiveWalletLayer
            { _pwlCreateWallet   = error "Not implemented!"
            , _pwlGetWalletIds   = error "Not implemented!"
            , _pwlGetWallet      = error "Not implemented!"
            , _pwlUpdateWallet   = error "Not implemented!"
            , _pwlDeleteWallet   = error "Not implemented!"

            , _pwlCreateAccount  = error "Not implemented!"
            , _pwlGetAccounts    = error "Not implemented!"
            , _pwlGetAccount     = error "Not implemented!"
            , _pwlUpdateAccount  = error "Not implemented!"
            , _pwlDeleteAccount  = error "Not implemented!"

            , _pwlCreateAddress  =
                \(V1.NewAddress mbSpendingPassword accIdx (V1.WalletId wId)) -> do
                    liftIO $ limitExecutionTimeTo (30 :: Second) CreateAddressTimeLimitReached $ do
                        case decodeTextAddress wId of
                             Left _ ->
                                 return $ Left (CreateAddressAddressDecodingFailed wId)
                             Right rootAddr -> do
                                let hdRootId = HD.HdRootId . InDb $ rootAddr
                                let hdAccountId = HD.HdAccountId hdRootId (HD.HdAccountIx accIdx)
                                let passPhrase = maybe mempty coerce mbSpendingPassword
                                res <- liftIO $ Kernel.createAddress passPhrase
                                                                     (AccountIdHdRnd hdAccountId)
                                                                     wallet
                                case res of
                                     Right newAddr -> return (Right newAddr)
                                     Left  err     -> return (Left $ CreateAddressError err)
            , _pwlGetAddresses   = error "Not implemented!"

            , _pwlApplyBlocks    = liftIO . invoke . Actions.ApplyBlocks
            , _pwlRollbackBlocks = liftIO . invoke . Actions.RollbackBlocks
            }

    -- The use of the unsafe constructor 'UnsafeRawResolvedBlock' is justified
    -- by the invariants established in the 'Blund'.
    blundToResolvedBlock :: Blund -> Maybe ResolvedBlock
    blundToResolvedBlock (b,u)
        = rightToJust b <&> \mainBlock ->
            fromRawResolvedBlock
            $ UnsafeRawResolvedBlock mainBlock Nothing spentOutputs'
        where
            spentOutputs' = map (map fromJust) $ undoTx u
            rightToJust   = either (const Nothing) Just

-- | Initialize the active wallet.
-- The active wallet is allowed to send transactions, as it has the full
-- 'WalletDiffusion' layer in scope.
bracketActiveWallet
    :: forall m n a. (MonadIO m, MonadMask m)
    => PassiveWalletLayer n
    -> Kernel.PassiveWallet
    -> WalletDiffusion
    -> (ActiveWalletLayer n -> m a) -> m a
bracketActiveWallet walletPassiveLayer passiveWallet walletDiffusion runActiveLayer =
    Kernel.bracketActiveWallet passiveWallet walletDiffusion $ \_activeWallet -> do
        bracket
          (return ActiveWalletLayer{..})
          (\_ -> return ())
          runActiveLayer
