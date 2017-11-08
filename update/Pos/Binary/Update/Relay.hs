module Pos.Binary.Update.Relay
       (
       ) where

import           Universum

import           Pos.Binary.Class              (Bi (..))
import           Pos.Binary.Infra              ()
import           Pos.Binary.Update.Core        ()
import           Pos.Communication.Types.Relay (DataMsg (..))
import           Pos.Core                      (HasConfiguration)
import           Pos.Crypto                    (hash)
import qualified Pos.Update.Core.Types         as U

----------------------------------------------------------------------------
-- Relay
----------------------------------------------------------------------------

instance HasConfiguration =>
         Bi (DataMsg (U.UpdateProposal, [U.UpdateVote])) where
    encode = encode . dmContents
    decode = do
        c@(up, votes) <- decode
        let !id = hash up
        unless (all ((id ==) . U.uvProposalId) votes) $ fail
            "decode@DataMsg@Update: vote's uvProposalId must be equal UpId"
        pure $ DataMsg c

instance HasConfiguration => Bi (DataMsg U.UpdateVote) where
    encode = encode . dmContents
    decode = DataMsg <$> decode
