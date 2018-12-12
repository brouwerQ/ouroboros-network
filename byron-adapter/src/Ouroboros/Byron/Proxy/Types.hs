{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE GADTSyntax #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}

{-# OPTIONS_GHC "-fwarn-incomplete-patterns" #-}

-- TODO probably better as Ouroboros.Proxy.Byron
module Ouroboros.Byron.Proxy.Types where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.STM (STM, atomically)
import Control.Concurrent.STM.TBQueue (TBQueue, newTBQueueIO, readTBQueue,
                                       writeTBQueue)
import Control.Concurrent.STM.TVar (TVar, modifyTVar', newTVarIO, readTVar)
import Control.Exception (Exception, throwIO)
import Control.Monad (forM, void)
import Control.Monad.Trans.Class (lift)
import Control.Lens ((^.))
import Data.Conduit (ConduitT, (.|), await, mapOutput, runConduit, yield)
import Data.List (maximumBy)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Ord (comparing)
import Data.Proxy (Proxy (..))
import Data.Tagged (Tagged (..), tagWith, untag)
import Data.Text (Text)
import Numeric.Natural (Natural)

import Pos.Binary.Class (decodeFull')
import Pos.Chain.Block (Block, BlockHeader, HeaderHash, MainBlockHeader,
                        getBlockHeader, headerHash)
import Pos.Chain.Delegation (ProxySKHeavy)
import Pos.Chain.Ssc (MCCommitment (..), MCOpening (..), MCShares (..),
                      MCVssCertificate (..), getCertId)
import Pos.Chain.Txp (TxAux (..), TxId, TxMsgContents (..))
import Pos.Chain.Update (BlockVersionData, UpdateProposal (..), UpdateVote (..),
                         UpId, VoteId)
import Pos.Communication (NodeId)
import Pos.Core (HasDifficulty(difficultyL), StakeholderId, addressHash,
                 getEpochOrSlot)
import Pos.Core.Chrono (NewestFirst (..), OldestFirst (..))
import Pos.Crypto (hash)
import Pos.DB.Class (Serialized (..), SerializedBlock)
import Pos.DB.Block (GetHeadersFromManyToError (..), GetHashesRangeError (..))
import Pos.Diffusion.Full (FullDiffusionConfiguration (..), diffusionLayerFull)
import Pos.Infra.Diffusion.Types
-- An ancient relic. Needed for the network configuration type.
import Pos.Infra.DHT.Real.Param (KademliaParams)
import Pos.Infra.Network.Types (NetworkConfig (..))
import Pos.Logic.Types hiding (streamBlocks)
import qualified Pos.Logic.Types as Logic

-- | Definitions required in order to run the Byron proxy.
data ByronProxyConfig = ByronProxyConfig
  { -- TODO see if we can't derive the block version data from the database.
    bpcAdoptedBVData     :: !BlockVersionData
  , bpcNetworkConfig     :: !(NetworkConfig KademliaParams)
  , bpcDiffusionConfig   :: !FullDiffusionConfiguration
    -- | How long rounds in the pools last, in microseconds. Data in the pools
    -- will live for at least this long, and at most 2 times this long.
  , bpcPoolRoundInterval :: !Natural
    -- | Size of the send queue. Sending atomic (non-block data) to Byron
    -- will block if this queue is full.
  , bpcSendQueueSize     :: !Natural
    -- | Size of the recv queue.
    -- TODO should probably let it be unlimited, since there is no backpressure
    -- in the Byron diffusion layer anyway, so failing to clear this queue
    -- will still cause a memory leak.
  , bpcRecvQueueSize     :: !Natural
  }

-- | TODO discover this as we work.
--
-- How will downloading work? This interface should simply make it possible,
-- rather than do it automatically.
-- The idea is to have one Byron consumer and one Byron producer, which will
-- be supported by this.
-- The producer actually comes out in a very roundabout way, through the
-- Logic's view of the database.
-- The consumer will also be weird I suppose. Will ultimately use existing
-- Diffusion streamBlocks.
data ByronProxy = ByronProxy
  { -- | A transaction which gives the current 'BestTip'.
    -- These are header announcements from the Byron cluster. They don't
    -- come in through a queue because there's no point in dealing with an
    -- earlier announcement when a later one is available.
    bestTip       :: STM (Maybe (BestTip BlockHeader))
    -- | Attempt to download the chain at a given header from a given peer.
    -- Those data can be taken from 'bestTip', but of course may no longer be
    -- correct at the time of the call.
    --
    -- TODO deal with the `Maybe t` in this type. Should it be there? It's
    -- used to indicate whether streaming is available, for fallback to
    -- batching.
  , downloadChain :: forall t .
                     NodeId
                  -> HeaderHash   -- of tip to request
                  -> [HeaderHash] -- of checkpoints
                  -> StreamBlocks Block IO t
                  -> IO (Maybe t)
    -- | Make Byron peers aware of this chain. It's expected that they will
    -- request it, which will be served by some database, so the blocks for
    -- this chain should be in it.
  , announceChain :: MainBlockHeader -> IO ()
    -- | Take the next atom from the Byron network (non-block data).
  , recvAtom      :: STM Atom
    -- | Send an atom to the Byron network. It's in STM because the send is
    -- performed asynchronously.
  , sendAtom      :: Atom -> STM ()
  }

-- | Mutable STM interface to a 'PoolRounds k v'.
newtype Pool k v = Pool
  { getPool :: TVar (PoolRounds k v)
  }

data PoolRounds k v = PoolRounds
  { poolCurrent :: !(Map k v)
  , poolRecent  :: !(Map k v)
  }

newRound :: PoolRounds k v -> PoolRounds k v
newRound pr = PoolRounds { poolCurrent = Map.empty, poolRecent = poolCurrent pr }

poolRoundsInsert :: ( Ord k ) => k -> v -> PoolRounds k v -> PoolRounds k v
poolRoundsInsert k v pr = pr { poolCurrent = Map.insert k v (poolCurrent pr) }

poolRoundsLookup :: ( Ord k ) => k -> PoolRounds k v -> Maybe v
poolRoundsLookup k pr =
  Map.lookup k (poolCurrent pr) <|> Map.lookup k (poolRecent pr)

poolInsert :: ( Ord k ) => k -> v -> Pool k v -> STM ()
poolInsert k v pool = modifyTVar' (getPool pool) (poolRoundsInsert k v)

poolLookup :: ( Ord k ) => k -> Pool k v -> STM (Maybe v)
poolLookup k pool = do
  rounds <- readTVar (getPool pool)
  pure $ poolRoundsLookup k rounds

-- | Create and use a 'Pool' with rounds of a given length in microseconds.
-- Data will remain in the pool for at least this interval.
-- We use 'Pool's to back the inv/req/data relay. The length must be
-- sufficiently long that we can expect all relaying to be done before this
-- interval has passed.
withPool :: Natural -> (Pool k v -> IO t) -> IO t
withPool usNat k = do
  poolVar <- newTVarIO (PoolRounds Map.empty Map.empty)
  withAsync (reaper poolVar) $ \_ -> k (Pool poolVar)
  where
  us :: Int
  us = fromEnum usNat
  reaper poolVar = threadDelay us >> swapRounds poolVar >> reaper poolVar
  swapRounds poolVar = atomically $ modifyTVar' poolVar newRound

-- | Make a logic layer `KeyVal` from a `Pool`. A `Tagged` is thrown on
-- because that's what the logic layer needs on all keys.
taggedKeyValFromPool
  :: ( Ord k )
  => Proxy tag
  -> (v -> k)
  -- ^ Get the key from the value.
  -> (v -> IO ())
  -- ^ Handle incoming data of this type.
  -> Pool k v
  -> KeyVal (Tagged tag k) v IO
taggedKeyValFromPool ptag keyFromValue process pool = KeyVal
  { -- This is needed by the old relay system, so it can make the INV
    -- announcements after a DATA messages has been processed.
    toKey = pure . tagWith ptag . keyFromValue
    -- Handle an INV: True if we don't have it, False if we do.
  , handleInv = \k -> fmap (maybe True (const False)) $ atomically $
      poolLookup (untag k) pool
    -- Handle a REQ: Nothing if we don't have it, Just if we do.
  , handleReq = \k -> atomically $ poolLookup (untag k) pool
    -- Handle a DATA: put it into the pool, process it, and give False to mean it
    -- should _not_ be relayed. For this Byron proxy, we'll never relay data
    -- received from Byron to another Byron node.
  , handleData = \v -> do
      atomically $ poolInsert (keyFromValue v) v pool
      process v
      pure False
  }

type TxPool = Pool TxId TxMsgContents
type UpProposalPool = Pool UpId (UpdateProposal, [UpdateVote])
type UpVotePool = Pool VoteId UpdateVote
type SscCommitmentPool = Pool StakeholderId MCCommitment
type SscOpeningPool = Pool StakeholderId MCOpening
type SscSharesPool = Pool StakeholderId MCShares
type SscVssCertPool = Pool StakeholderId MCVssCertificate

-- | Atoms are data which are not blocks.
data Atom where
  Transaction    :: TxMsgContents -> Atom
  UpdateProposal :: (UpdateProposal, [UpdateVote]) -> Atom
  UpdateVote     :: UpdateVote -> Atom
  Commitment     :: MCCommitment -> Atom
  Opening        :: MCOpening -> Atom
  Shares         :: MCShares -> Atom
  VssCertificate :: MCVssCertificate -> Atom
  Delegation     :: ProxySKHeavy -> Atom

deriving instance Show Atom

-- To get atoms from Shelley to Byron we put them into the pool and then
-- send them using the diffusion layer.
--
-- To get them from Byron to Shelley we use the relay mechanism built in to
-- the diffusion layer: it will put the thing into the relevant pool, then
-- make and deposit an `Atom` into a queue.

sendAtomToByron :: Diffusion IO -> Atom -> IO ()
sendAtomToByron diffusion atom = case atom of

  Transaction tx -> void $ sendTx diffusion (getTxMsgContents tx)

  UpdateProposal (up, uvs) -> sendUpdateProposal diffusion (hash up) up uvs
  UpdateVote uv            -> sendVote diffusion uv

  Opening (MCOpening sid opening)      -> sendSscOpening diffusion sid opening
  Shares (MCShares sid shares)         -> sendSscShares diffusion sid shares
  VssCertificate (MCVssCertificate vc) -> sendSscCert diffusion (getCertId vc) vc
  Commitment (MCCommitment commitment) -> sendSscCommitment diffusion sid commitment
    where
    (pk, _, _) = commitment
    sid = addressHash pk

  Delegation psk -> sendPskHeavy diffusion psk

-- | Information about the best tip from the Byron network.
data BestTip tip = BestTip
  { -- | This tip ...
    btTip :: !tip
    -- | ... was announced by these peers.
  , btPeers  :: !(NonEmpty NodeId)
  }

deriving instance Show tip => Show (BestTip tip)
deriving instance Eq tip => Eq (BestTip tip)

instance Functor BestTip where
  fmap f bt = bt { btTip = f (btTip bt) }

data HeaderComparison where
  -- | Same as in the very same header.
  Same      :: HeaderComparison
  -- | Better as in strictly longer (more difficult).
  Better    :: HeaderComparison
  -- | Better as in shorter or equal length but not equal header.
  NotBetter :: HeaderComparison

-- | Equality is done via the header hash. Adjective refers to the first
-- in relation to the second: first is `Better` than the second.
compareHeaders
  :: BlockHeader
  -> BlockHeader
  -> HeaderComparison
compareHeaders bhl bhr = case headerHash bhl == headerHash bhr of
  True  -> Same
  False -> case (bhl ^. difficultyL) `compare` (bhr ^. difficultyL) of
    GT -> Better
    _  -> NotBetter

-- | Does not keep duplicates out of the set of peers, which is fine given how
-- it's used: we expect a better header to come in later and throw away the
-- previous list. Also we don't expect a peer to announce the same header
-- twice.
updateBestTip :: NodeId -> BlockHeader -> BestTip BlockHeader -> BestTip BlockHeader
updateBestTip peer header bt = case compareHeaders header (btTip bt) of
  NotBetter -> bt
  Same -> bt { btPeers = NE.cons peer (btPeers bt) }
  Better -> BestTip { btTip = header, btPeers = peer NE.:| [] }

updateBestTipMaybe :: NodeId -> BlockHeader -> Maybe (BestTip BlockHeader) -> BestTip BlockHeader
updateBestTipMaybe peer header = maybe bt (updateBestTip peer header)
  where
  bt = BestTip { btTip = header, btPeers = peer NE.:| [] }

-- | Serving blocks to a Byron cluster requires a database of blocks keyed
-- on hashes.
--
data ByronBlockSource m = ByronBlockSource
  { -- | Streams blocks from and including the one at this hash, in
    -- older-to-newer order, or stops without producing anything if this hash is not known.
    bbsStream :: HeaderHash -> ConduitT () SerializedBlock m ()
  , bbsTip    :: m SerializedBlock
  }

bbsStreamBlocks
  :: forall m .
     ( Monad m )
  => ByronBlockSource m
  -> (forall a . Text -> m a)
  -- ^ If decoding fails.
  -> HeaderHash
  -> ConduitT () Block m ()
bbsStreamBlocks bbs onErr hh = bbsStream bbs hh .| decode
  where
  decode :: ConduitT SerializedBlock Block m ()
  decode = do
    mSer <- await
    case fmap (decodeFull' . unSerialized) mSer of
      Nothing         -> pure ()
      Just (Left err) -> lift $ onErr err
      Just (Right b)  -> yield b >> decode

bbsTipBlock
  :: forall m .
     ( Monad m )
  => ByronBlockSource m
  -> (forall a . Text -> m a)
  -> m Block
bbsTipBlock bbs onErr = bbsTip bbs >>= \ser -> case decodeFull' (unSerialized ser) of
  Left err -> onErr err
  Right b  -> pure b

bbsGetSerializedBlock
  :: ( Monad m )
  => ByronBlockSource m
  -> HeaderHash
  -> m (Maybe SerializedBlock)
bbsGetSerializedBlock bbs hh = runConduit (bbsStream bbs hh .| await)

bbsGetBlockHeader
  :: forall m .
     ( Monad m )
  => ByronBlockSource m
  -> (forall a . Text -> m a)
  -> HeaderHash
  -> m (Maybe BlockHeader)
bbsGetBlockHeader bbs onErr hh = runConduit (bbsStreamBlocks bbs onErr hh .| consumeOne)
  where
  consumeOne :: ConduitT Block x m (Maybe BlockHeader)
  consumeOne = (fmap . fmap) Pos.Chain.Block.getBlockHeader await

-- TODO we're supposed to give 'Either GetHashesRangeError' but let's
-- fill that in later at the use site.
--
-- Runs the block stream conduit from the first hash until either
-- - the second hash is encountered
-- - the optional limit, or max bound of Word, iterations is reached
-- - the stream ends before either of these
--
-- The resulting list includes both endpoints.
bbsGetHashesRange
  :: forall m .
     ( Monad m )
  => ByronBlockSource m
  -> (forall a . Text -> m a)
  -> Maybe Word
  -> HeaderHash
  -> HeaderHash
  -> m (Maybe (OldestFirst NonEmpty HeaderHash))
bbsGetHashesRange bbs onErr mLimit from to = runConduit (producer .| consumer)
  where
  producer :: ConduitT () HeaderHash m ()
  producer = mapOutput headerHash (bbsStreamBlocks bbs onErr from)
  consumer :: ConduitT HeaderHash x m (Maybe (OldestFirst NonEmpty HeaderHash))
  consumer = goConsumer (fromMaybe maxBound mLimit) []
  goConsumer :: Word
             -> [HeaderHash]
             -> ConduitT HeaderHash x m (Maybe (OldestFirst NonEmpty HeaderHash))
  goConsumer 0 _   = pure Nothing
  goConsumer n acc = do
    next <- await
    case next of
      Nothing -> pure Nothing
      Just it -> if it == to
                 then pure (Just (OldestFirst (NE.reverse (it NE.:| acc))))
                 else goConsumer (n-1) (it : acc)

-- Find the first checkpoint that's in the database and then stream from
-- there.
-- 
-- we're supposed to give 'Either GetHeadersFromManyToError' but will fill that
-- in later at the use site.
--
-- How is it done in byron full logic layer? For every checkpoint given, it
-- will check whether it's in the database, filtering out those which are not.
-- Then it takes the newest checkpoint that's in the database, and loads
-- from there to the endpoint (Maybe HeaderHash or the current tip if it's
-- Nothing).
-- We'll do the same thing, even though it's probably not ideal.
--
-- One difference: we demand a tip (no 'Maybe HeaderHash'). We'll fill that
-- in at the logic layer using getTip.
bbsGetBlockHeaders
  :: forall m .
     ( Monad m )
  => ByronBlockSource m
  -> (forall a . Text -> m a)
  -> Maybe Word
  -> NonEmpty HeaderHash
  -> HeaderHash
  -> m (Maybe (NewestFirst NonEmpty BlockHeader))
bbsGetBlockHeaders bbs onErr mLimit checkpoints tip = do
  knownCheckpoints <- fmap catMaybes $ forM (NE.toList checkpoints) (bbsGetBlockHeader bbs onErr)
  let newestCheckpoint = maximumBy (comparing getEpochOrSlot) knownCheckpoints
  case knownCheckpoints of
    []    -> pure Nothing
    -- Now we know `newestCheckpoints` is not _|_
    _ : _ -> runConduit $
         producer (headerHash newestCheckpoint)
      .| consumer (fromMaybe maxBound mLimit) []
  where
  producer :: HeaderHash -> ConduitT () BlockHeader m ()
  producer = mapOutput Pos.Chain.Block.getBlockHeader . bbsStreamBlocks bbs onErr
  consumer :: Word
           -> [BlockHeader]
           -> ConduitT BlockHeader x m (Maybe (NewestFirst NonEmpty BlockHeader))
  consumer 0 _   = pure Nothing
  consumer n acc = do
    next <- await
    case next of
      Nothing        -> pure Nothing
      Just blkHeader ->
        if headerHash blkHeader == tip
        then pure $ Just $ NewestFirst $ blkHeader NE.:| acc
        else consumer (n-1) (blkHeader : acc)

-- | See Logic.getLcaMainChain
-- This is done by reading from the start of the input list, and stopping once
-- we find a hash which does not match the corresponding one in the input list.
bbsGetLcaMainChain
  :: forall m .
     ( Monad m )
  => ByronBlockSource m
  -> (forall a . Text -> m a)
  -> OldestFirst [] HeaderHash
  -> m (NewestFirst [] HeaderHash, OldestFirst [] HeaderHash)
bbsGetLcaMainChain bbs onErr (OldestFirst otherChain) = case otherChain of
  -- No starting point, but the answer is obvious.
  [] -> pure (NewestFirst [], OldestFirst [])
  -- Begin producing from the oldest point. 
  -- The consumer will pull the next hash and compare it to the expectation.
  (oldest : others) -> runConduit (producer oldest .| consumer (oldest : others) [])
  where
  producer :: HeaderHash -> ConduitT () HeaderHash m ()
  producer hh = mapOutput headerHash (bbsStreamBlocks bbs onErr hh)
  consumer :: [HeaderHash] -- The rest of the input chain (oldest first)
           -> [HeaderHash] -- Those which we've confirmed to be in the db
           -> ConduitT HeaderHash x m (NewestFirst [] HeaderHash, OldestFirst [] HeaderHash)
  consumer []          acc = pure (NewestFirst acc, OldestFirst [])
  consumer (hh : rest) acc = do
    mHh <- await
    case mHh of
      Nothing  -> pure (NewestFirst acc, OldestFirst (hh : rest))
      Just hh' -> if hh == hh'
                  then consumer rest (hh : acc)
                  else pure (NewestFirst acc, OldestFirst (hh : otherChain))

data BlockDecodeError = BlockDecodeError !Text
  deriving (Show, Eq)

instance Exception BlockDecodeError

withByronProxy
  :: ByronProxyConfig
  -> ByronBlockSource IO
  -> (ByronProxy -> IO t)
  -> IO t
withByronProxy bpc bbs k =
  -- Create pools for all relayed data.
  -- TODO what about for delegation certificates?
  withPool (bpcPoolRoundInterval bpc) $ \(txPool :: TxPool) ->
  withPool (bpcPoolRoundInterval bpc) $ \(upProposalPool :: UpProposalPool) ->
  withPool (bpcPoolRoundInterval bpc) $ \(upVotePool :: UpVotePool) ->
  withPool (bpcPoolRoundInterval bpc) $ \(sscCommitmentPool :: SscCommitmentPool) ->
  withPool (bpcPoolRoundInterval bpc) $ \(sscOpeningPool :: SscOpeningPool) ->
  withPool (bpcPoolRoundInterval bpc) $ \(sscSharesPool :: SscSharesPool) ->
  withPool (bpcPoolRoundInterval bpc) $ \(sscVssCertPool :: SscVssCertPool) -> do

    -- The best announced block header, and the identifiers of every peer which
    -- announced it. `Nothing` whenever there is no known announcement. It will
    -- never go from `Just` to `Nothing`, it only starts as `Nothing`.
    tipsTVar :: TVar (Maybe (BestTip BlockHeader)) <- newTVarIO Nothing

    -- Send and receive bounded queues for atomic data (non-block).
    -- The receive queue is populated by the relay system by way of the logic
    -- layer. The send queue is emptied by a thread spawned here which uses
    -- the diffusion layer to send (ultimately by way of the outbound queue).
    atomRecvQueue :: TBQueue Atom <- newTBQueueIO (bpcRecvQueueSize bpc)
    atomSendQueue :: TBQueue Atom <- newTBQueueIO (bpcSendQueueSize bpc)

    -- How about block downloads?
    -- Is it worth it to do batching for immediate continuations?

    let byronProxy :: Diffusion IO -> ByronProxy
        byronProxy diffusion = ByronProxy
          { bestTip = takeBestTip
          , downloadChain = streamBlocks diffusion
          , announceChain = announceBlockHeader diffusion
          , recvAtom = readTBQueue atomRecvQueue
          , sendAtom = writeTBQueue atomSendQueue
          }

        takeBestTip :: STM (Maybe (BestTip BlockHeader))
        takeBestTip = readTVar tipsTVar

        sendingThread :: forall x . Diffusion IO -> IO x
        sendingThread diffusion = do
          atom <- atomically $ readTBQueue atomSendQueue
          sendAtomToByron diffusion atom
          sendingThread diffusion

        blockDecodeError :: forall x . Text -> IO x
        blockDecodeError = throwIO . BlockDecodeError

        mkLogic = \_diffusion -> Logic
          { -- This is only used to determine the message size limit on requesting
            -- block headers, which is sadly a byte limit on a message which contains
            -- _all_ of the headers. It's basically legacy, we'll be streaming blocks
            -- rather than batching.
            getAdoptedBVData   = pure (bpcAdoptedBVData bpc)
            -- Recovery mode is useless. We don't use it.
          , recoveryInProgress = pure False

            -- When a new block header announcement comes in, we update the best
            -- Byron tip `TVar`.
          , postBlockHeader    = \header peer -> atomically $
              modifyTVar' tipsTVar $ Just . updateBestTipMaybe peer header

            -- For these, we just need little mempools.
            -- Must be able to poke these mempools from Shelley, too
          , postTx            = taggedKeyValFromPool
              (Proxy :: Proxy TxMsgContents)
              (hash . taTx . getTxMsgContents)
              (atomically . writeTBQueue atomRecvQueue . Transaction)
              txPool
          , postUpdate        = taggedKeyValFromPool
              (Proxy :: Proxy (UpdateProposal, [UpdateVote]))
              (hash . fst)
              (atomically . writeTBQueue atomRecvQueue . UpdateProposal)
              upProposalPool
          , postVote          = taggedKeyValFromPool
              (Proxy :: Proxy UpdateVote)
              (\uv -> (uvProposalId uv, uvKey uv, uvDecision uv))
              (atomically . writeTBQueue atomRecvQueue . UpdateVote)
              upVotePool
          , postSscCommitment = taggedKeyValFromPool
              (Proxy :: Proxy MCCommitment)
              (\(MCCommitment (pk, _, _)) -> addressHash pk)
              (atomically . writeTBQueue atomRecvQueue . Commitment)
              sscCommitmentPool
          , postSscOpening    = taggedKeyValFromPool
              (Proxy :: Proxy MCOpening)
              (\(MCOpening key _) -> key)
              (atomically . writeTBQueue atomRecvQueue . Opening)
              sscOpeningPool
          , postSscShares     = taggedKeyValFromPool
              (Proxy :: Proxy MCShares)
              (\(MCShares key _) -> key)
              (atomically . writeTBQueue atomRecvQueue . Shares)
              sscSharesPool
          , postSscVssCert    = taggedKeyValFromPool
              (Proxy :: Proxy MCVssCertificate)
              (\(MCVssCertificate vc) -> getCertId vc)
              (atomically . writeTBQueue atomRecvQueue . VssCertificate)
              sscVssCertPool

            -- TODO FIXME what to do for this? Should we relay it using a pool?
            -- I'm not sure if the full diffusion/logic even does relaying of
            -- these.
          , postPskHeavy = \_ -> pure True

          -- Given a bunch of hashes, find LCA with main chain.
          -- With only the immutable, we just need to get the tip and that
          -- will be the LCA if it's in the set of hashes.
          --   tip
          , getLcaMainChain      = bbsGetLcaMainChain bbs blockDecodeError

          -- MsgGetHeaders conversation
          -- Needs the index.
          , Logic.getBlockHeader = bbsGetBlockHeader bbs blockDecodeError
          -- MsgGetHeaders conversation
          -- Needs the index.
          , getBlockHeaders      = \mLimit checkpoints mTip -> do
              tip <- case mTip of
                Just tip -> pure tip
                Nothing -> fmap headerHash (bbsTipBlock bbs blockDecodeError)
              result <- bbsGetBlockHeaders bbs blockDecodeError mLimit checkpoints tip
              case result of
                Nothing -> pure $ Left $ GHFBadInput ""
                Just it -> pure $ Right it
          -- MsgGetHeaders conversation
          -- Needs only 'tip'
          , getTip               = bbsTipBlock bbs blockDecodeError
          -- GetBlocks conversation
          -- Needs the index, then we can stream from there.
          , getHashesRange       = \mLimit from to -> do
              result <- bbsGetHashesRange bbs blockDecodeError mLimit from to
              case result of
                Nothing -> pure $ Left $ GHRBadInput ""
                Just it -> pure $ Right it
          -- GetBlocks conversation
          -- Needs the index.
          , getSerializedBlock   = bbsGetSerializedBlock bbs
          -- StreamBlocks conversation
          -- Needs an index, then stream from there.
          , Logic.streamBlocks   = bbsStream bbs

          }

        networkConfig = bpcNetworkConfig bpc
        fdconf = bpcDiffusionConfig bpc

    diffusionLayerFull fdconf networkConfig Nothing mkLogic $ \diffusionLayer -> do
      runDiffusionLayer diffusionLayer $ withAsync (sendingThread (diffusion diffusionLayer)) $
        \_ -> k (byronProxy (diffusion diffusionLayer))
