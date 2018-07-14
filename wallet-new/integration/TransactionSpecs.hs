{-# LANGUAGE RankNTypes    #-}
{-# LANGUAGE TupleSections #-}

module TransactionSpecs (transactionSpecs) where

import           Universum
import qualified Serokell.Util.Base16 as B16
-- import           Formatting (build, bprint, (%))

import qualified Cardano.Crypto.Wallet as CC
import           Cardano.Wallet.API.V1.Errors hiding (describe)
import           Cardano.Wallet.Client.Http
import           Pos.Binary.Class (decodeFull')
import qualified Pos.Core as Core
import           Pos.Crypto (SecretKey, SignTag (..), Signature (..), emptyPassphrase,
                             encToPublic, encToSecret, encodeBase58PublicKey, hash,
                             noPassEncrypt, sign)
import           Pos.Crypto.HD (ShouldCheckPassphrase (..))

import           Test.Hspec
import           Test.QuickCheck (arbitrary, generate)

import           Util


transactionSpecs :: WalletRef -> WalletClient IO -> Spec
transactionSpecs wRef wc = do
    describe "Transactions" $ do
        it "Posted transactions appear in the index" $ do
            genesis <- makeGenesisWallet wc
            (fromAcct, _) <- getFirstAccountAndAddress wc genesis

            wallet <- sampleWallet wRef wc
            (toAcct, toAddr) <- getFirstAccountAndAddress wc wallet

            let payment = Payment
                    { pmtSource =  PaymentSource
                        { psWalletId = walId genesis
                        , psAccountIndex = accIndex fromAcct
                        }
                    , pmtDestinations = pure PaymentDistribution
                        { pdAddress = addrId toAddr
                        , pdAmount = halfOf (accAmount fromAcct)
                        }
                    , pmtGroupingPolicy = Nothing
                    , pmtSpendingPassword = Nothing
                    }
                halfOf (V1 c) = V1 (Core.mkCoin (Core.getCoin c `div` 2))

            etxn <- postTransaction wc payment

            txn <- fmap wrData etxn `mustBe` _OK

            eresp <- getTransactionIndex wc (Just (walId wallet)) (Just (accIndex toAcct)) Nothing
            resp <- fmap wrData eresp `mustBe` _OK

            map txId resp `shouldContain` [txId txn]

        it "Estimate fees of a well-formed transaction" $ do
            ws <- (,)
                <$> (randomCreateWallet >>= createWalletCheck wc)
                <*> (randomCreateWallet >>= createWalletCheck wc)

            ((fromAcct, _), (_toAcct, toAddr)) <- (,)
                <$> getFirstAccountAndAddress wc (fst ws)
                <*> getFirstAccountAndAddress wc (snd ws)

            let amount = V1 (Core.mkCoin 42)

            let payment = Payment
                    { pmtSource = PaymentSource
                        { psWalletId = walId (fst ws)
                        , psAccountIndex = accIndex fromAcct
                        }
                    , pmtDestinations = pure PaymentDistribution
                        { pdAddress = addrId toAddr
                        , pdAmount = amount
                        }
                    , pmtGroupingPolicy = Nothing
                    , pmtSpendingPassword = Nothing
                    }

            efee <- getTransactionFee wc payment
            case efee of
                Right fee ->
                    feeEstimatedAmount (wrData fee)
                        `shouldSatisfy`
                            (> amount)
                Left (ClientWalletError (NotEnoughMoney _)) ->
                    pure ()
                Left err ->
                    expectationFailure $
                        "Expected either a successful fee or a NotEnoughMoney "
                        <> " error, got: "
                        <> show err

        it "Fails if you spend too much money" $ do
            wallet <- sampleWallet wRef wc
            (toAcct, toAddr) <- getFirstAccountAndAddress wc wallet

            let payment = Payment
                    { pmtSource =  PaymentSource
                        { psWalletId = walId wallet
                        , psAccountIndex = accIndex toAcct
                        }
                    , pmtDestinations = pure PaymentDistribution
                        { pdAddress = addrId toAddr
                        , pdAmount = tooMuchCash (accAmount toAcct)
                        }
                    , pmtGroupingPolicy = Nothing
                    , pmtSpendingPassword = Nothing
                    }
                tooMuchCash (V1 c) = V1 (Core.mkCoin (Core.getCoin c * 2))
            etxn <- postTransaction wc payment

            void $ etxn `mustBe` _Failed

        it "Create unsigned transaction and submit it to the blockchain" $ do
            -- Create genesis wallet, it is initial source of money,
            -- we will use it to send money to the source wallet before test payment.
            genesisWallet <- makeGenesisWallet wc
            (genesisAccount, _) <- getFirstAccountAndAddress wc genesisWallet

            -- Create a keys for the source wallet.
            (srcWalletEncRootSK, srcWalletRootPK) <- makeWalletRootKeys

            -- print $ bprint ("__________PkWitness: key = "%build) srcWalletRootPK

            -- Create and store new address for source wallet,
            -- we need it to send money from genesis wallet, before test payment.
            (srcWalletAddress, srcWalletAddressDerivedSK) <- makeFirstAddress srcWalletEncRootSK
            -- Create external wallet, the source of test payment.
            (srcExtWallet, defaultSrcAccount) <- makeExternalWalletBasedOn srcWalletRootPK
            storeAddressInWalletAccount srcExtWallet defaultSrcAccount srcWalletAddress

            -- Most likely that we'll have some change after test payment
            -- (if test payment's amount is smaller that 'srcExtWallet' balance),
            -- so we must provide change address for it.
            srcWalletChangeAddress <- makeAnotherAddress srcWalletEncRootSK defaultSrcAccount
            storeAddressInWalletAccount srcExtWallet defaultSrcAccount srcWalletChangeAddress

            -- Send some money to source wallet.
            let initAmountInLovelaces = 1000000000
                initPayment = makePayment genesisWallet
                                          genesisAccount
                                          srcWalletAddress
                                          initAmountInLovelaces
            txResponse <- postTransaction wc initPayment
            void $ txResponse `mustBe` _OK

            -- Now source wallet contains some money.
            srcExtWalletBalance <- getWalletBalanceInLovelaces wc srcExtWallet
            srcExtWalletBalance `shouldSatisfy` (> 0)

            -- Create another external wallet, the destination of test payment.
            (dstWalletEncRootSK, dstWalletRootPK) <- makeWalletRootKeys

            -- Create and store new address for destination wallet,
            -- we need it to send money from source wallet.
            (dstWalletAddress, _) <- makeFirstAddress dstWalletEncRootSK
            (dstExtWallet, defaultDstAccount) <- makeExternalWalletBasedOn dstWalletRootPK
            storeAddressInWalletAccount dstExtWallet defaultDstAccount dstWalletAddress

            -- Test payment.
            let testAmountInLovelaces = 100000000
                testPayment = makePayment srcExtWallet
                                          defaultSrcAccount
                                          dstWalletAddress
                                          testAmountInLovelaces
                changeAddressAsBase58 = Core.addrToBase58Text srcWalletChangeAddress
                testPaymentWithChangeAddress = PaymentWithChangeAddress testPayment changeAddressAsBase58

            rawTxResponse <- postUnsignedTransaction wc testPaymentWithChangeAddress
            rawTx <- rawTxResponse `mustBe` _OK

            -- Now we have a raw transaction, but it wasn't piblished yet,
            -- let's sign it (as if Ledger device did it).
            let RawTransaction txInHexFormat _aap = wrData rawTx
                Right txSerialized = B16.decode txInHexFormat
                Right (tx :: Core.Tx) = decodeFull' txSerialized
                txHash = hash tx
                protocolMagic = Core.ProtocolMagic 125 -- Some random value, it's just for test cluster.
                Signature txSignature = sign protocolMagic
                                             SignTx
                                             srcWalletAddressDerivedSK
                                             txHash
                rawSignature = CC.unXSignature txSignature
                _txSignatureInHexFormat = B16.encode rawSignature
                srcWalletRootPKAsBase58 = encodeBase58PublicKey srcWalletRootPK
                signedTx = SignedTransaction srcWalletRootPKAsBase58
                                             txInHexFormat
                                             []

            -- Now we have signed transaction, let's publish it in the blockchain.
            signedTxResponse <- postSignedTransaction wc signedTx
            void $ signedTxResponse `mustBe` _OK

            -- Check current balance of destination wallet.
            --dstExtWalletBalance <- getWalletBalanceInLovelaces wc dstExtWallet
            --dstExtWalletBalance `shouldSatisfy` (> 0)
  where
    makePayment srcWallet srcAccount dstAddress amount = Payment
        { pmtSource = PaymentSource
            { psWalletId = walId srcWallet
            , psAccountIndex = accIndex srcAccount
            }
        , pmtDestinations = pure PaymentDistribution
            { pdAddress = V1 dstAddress
            , pdAmount = V1 (Core.mkCoin amount)
            }
        , pmtGroupingPolicy = Nothing
        , pmtSpendingPassword = Nothing
        }

    makeFirstAddress encSecretKey = do
        -- We have to create HD address because we will sync this wallet
        -- with the blockchain to see its actual balance.
        let forBootstrapEra = Core.IsBootstrapEraAddr True
            Just (anAddress, derivedEncSK) =
                Core.deriveFirstHDAddress forBootstrapEra
                                          emptyPassphrase
                                          encSecretKey
            derivedPK = encToPublic derivedEncSK
            addressCreatedFromThisPK = Core.checkPubKeyAddress derivedPK anAddress

        addressCreatedFromThisPK `shouldBe` True

        pure (anAddress, encToSecret derivedEncSK)

    makeAnotherAddress encSecretKey anAccount = do
        addrIndex <- randomAddressIndex
        let forBootstrapEra = Core.IsBootstrapEraAddr True
            passCheck = ShouldCheckPassphrase True
            Just (anAddress, derivedEncSecretKey) =
                Core.deriveLvl2KeyPair forBootstrapEra
                                       passCheck
                                       emptyPassphrase
                                       encSecretKey
                                       (accIndex anAccount)
                                       addrIndex
            derivedPublicKey = encToPublic derivedEncSecretKey
            addressCreatedFromThisPK = Core.checkPubKeyAddress derivedPublicKey anAddress

        addressCreatedFromThisPK `shouldBe` True

        pure anAddress

    storeAddressInWalletAccount wallet anAccount anAddress = do
        -- Store this HD-address in the wallet's account.
        let anAddressAsBase58 = Core.addrToBase58Text anAddress
        storeResponse <- postStoreAddress wc
                                          (walId wallet)
                                          (accIndex anAccount)
                                          anAddressAsBase58
        void $ storeResponse `mustBe` _OK

    makeExternalWalletBasedOn publicKey = do
        newExtWallet <- randomExternalWalletWithPublicKey CreateWallet publicKey
        extWallet <- createExternalWalletCheck wc newExtWallet
        defaultAccount <- firstAccountInExtWallet wc extWallet
        pure (extWallet, defaultAccount)

    makeWalletRootKeys = do
        rootSK <- randomSK
        let encRootSK = noPassEncrypt rootSK
            rootPK    = encToPublic encRootSK
        pure (encRootSK, rootPK)

    randomSK :: IO SecretKey
    randomSK = generate arbitrary

    randomAddressIndex :: IO Word32
    randomAddressIndex = generate arbitrary
