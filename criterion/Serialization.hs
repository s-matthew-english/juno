{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Criterion.Main

import qualified Crypto.Sign.Ed25519 as Ed

import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Serialize
import Data.ByteString (ByteString)
-- import qualified Data.ByteString as SB
import qualified Data.ByteString.Lazy as LB
import GHC.Generics
import Data.Monoid
import GHC.Word

import qualified Data.Binary.Serialise.CBOR.Read     as CBR
import qualified Data.Binary.Serialise.CBOR.Write    as CBW
import qualified Data.Binary.Serialise.CBOR.Encoding as CBE
import qualified Data.Binary.Serialise.CBOR.Decoding as CBD
import qualified Data.Binary.Serialise.CBOR.Class as CBC
import qualified Data.Binary.Serialise.CBOR as CB

import Juno.Runtime.Types

main :: IO ()
main = defaultMain
  [ bgroup "Ed Crypto"
    [ bench "Sign 256B" $
        whnf (Ed.dsign edPrivKey) edB256
    , bench "Sign 512B" $
        whnf (Ed.dsign edPrivKey) edB512
    , bench "Sign 1024B" $
        whnf (Ed.dsign edPrivKey) edB1024
    , bench "Sign 2048B" $
        whnf (Ed.dsign edPrivKey) edB2048
    , bench "Sign 4096B" $
        whnf (Ed.dsign edPrivKey) edB4096
    , bench "Verify 256B" $
        whnf (Ed.dverify edPubKey edB256) edSigB256
    , bench "Verify 512B" $
        whnf (Ed.dverify edPubKey edB512) edSigB512
    , bench "Verify 1024B" $
        whnf (Ed.dverify edPubKey edB1024) edSigB1024
    , bench "Verify 2048B" $
        whnf (Ed.dverify edPubKey edB2048) edSigB2048
    , bench "Verify 4096B" $
        whnf (Ed.dverify edPubKey edB4096) edSigB4096
    ]
  , bgroup "CMD (Old Method)" [
      bench "Verify CMD" $
        whnf ((\(Right v) -> v) . oldCmdVerify ClientMsg keySet) ocmdSignedRPC
    , bench "Decode & Verify Raw BS" $
        whnf ((\(Right v) -> v) . oldCmdDecode ClientMsg keySet) ocmdSerRPC
    , bench "Sign and Encode" $
        whnf (encode . oldCmdSign) ocmdRPC
    , bench "Encode pre-signed" $
        whnf encode ocmdSignedRPC
    ]
  , bgroup "CMD (Digest)" [
      bench "Verify & Decode SignedRPC" $
        whnf ((\(Right v) -> v) . fromWire defaultReceivedAt keySet :: SignedRPC -> Command) cmdSignedRPC1
    , bench "Verify & Decode Raw BS" $
        whnf (either error ((\(Right v) -> v) . fromWire defaultReceivedAt keySet) . decode :: ByteString -> Command) cmdSignedRpc1BS
    , bench "Sign and Encode" $
        whnf (encode . toWire nodeIdClient pubKeyClient privKeyClient) cmdRPC1
    , bench "Encode pre-signed" $
        whnf (encode . toWire nodeIdClient pubKeyClient privKeyClient) cmdRpc1Received
    ]
  , bgroup "CMD (CBOR)" [
      bench "Verify & Decode SignedRPC" $
        whnf ((\(Right v) -> v) . fromWireCBOR defaultReceivedAt keySet :: SignedRPC -> Command) cmdSignedRpcCBOR
    , bench "Verify & Decode Raw BS" $
        whnf (either error ((\(Right v) -> v) . fromWireCBOR defaultReceivedAt keySet) . CBR.deserialiseFromBytes CBC.decode :: LB.ByteString -> Command) cmdSignedRpcCborBS
    , bench "Sign and Encode" $
        whnf (encode . toWireCBOR nodeIdClient pubKeyClient privKeyClient) cmdRPC1
    , bench "Encode pre-signed" $
        whnf (encode . toWireCBOR nodeIdClient pubKeyClient privKeyClient) cmdRpc1Received
    ]
  , bgroup "Empty AE (Digest)" [
      bench "Verify & Decode SignedRPC" $
        whnf ((\(Right v) -> v) . fromWire defaultReceivedAt keySet :: SignedRPC -> AppendEntries) aeEmptySignedRPC
    , bench "Verify & Decode Raw BS" $
        whnf (either error ((\(Right v) -> v) . fromWire defaultReceivedAt keySet) . decode :: ByteString -> AppendEntries) aeEmptySignedRpcBS
    , bench "Sign and Encode" $
        whnf (encode . toWire nodeIdLeader pubKeyLeader privKeyLeader) aeEmptyRPC
    , bench "Encode pre-signed" $
        whnf (encode . toWire nodeIdLeader pubKeyLeader privKeyLeader) aeEmptyRpcReceived
    ]
  , bgroup "AE Two LogEntries (Old Method)" [
      bench "Verify AE" $
        whnf oldAeVerify oaeRPC'
    , bench "Decode & Verify Raw BS" $
        whnf oldAeDecode oaeSerRPC
    , bench "Sign and Encode" $
        whnf (encode . oldAeSign) oaeRPC
    , bench "Encode pre-signed" $
        whnf encode oaeRPC'
    ]
  , bgroup "AE Two LogEntries (Digest)" [
      bench "Verify & Decode SignedRPC" $
        whnf ((\(Right v) -> v) . fromWire defaultReceivedAt keySet :: SignedRPC -> AppendEntries) aeSignedRPC
    , bench "Verify & Decode Raw BS" $
        whnf (either error ((\(Right v) -> v) . fromWire defaultReceivedAt keySet) . decode :: ByteString -> AppendEntries) aeSignedRpcBS
    , bench "Sign and Encode" $
        whnf (encode . toWire nodeIdLeader pubKeyLeader privKeyLeader) aeRPC
    , bench "Encode pre-signed" $
        whnf (encode . toWire nodeIdLeader pubKeyLeader privKeyLeader) aeRpcReceived
    ]
  ]

-- ##########################################################
-- ####### All the stuff we need to actually run this #######
-- ##########################################################

-- #######################################################################
-- NodeID's + Keys for Client (10002), Leader (10000) and Follower (10001)
-- #######################################################################
nodeIdLeader, nodeIdFollower, nodeIdClient :: NodeID
nodeIdLeader = NodeID "localhost" 10000
nodeIdFollower = NodeID "localhost" 10001
nodeIdClient = NodeID "localhost" 10002

privKeyLeader, privKeyFollower, privKeyClient :: SecretKey
privKeyLeader = SecretKey "\132h\138\225\233\237%\\\SOnZH\196\138\232\&7\239c'p)YE\192\136\DC3\217\170N\231n\236\199\NAK\238\171\\\161\222\247\186/\DC3\204Qqd\225}\202\150e~q\255;\223\233\211:\211\SUBT\145"
privKeyFollower = SecretKey "\244\228\130\r\213\134\171\205!\141z\238\nJd\170\208%_\188\196\150\152$\178\153\SO\240\192\&4\202Q\164}\DC2`\245Bh-Mj!\227\220A\EOTfN\129\&5\213Z\ENQ\155\129\155d\SUB\129\194&\SUB4"
privKeyClient = SecretKey "h\129\140\207.\166\210\253\STXo\FS\201\186\185a\202\240\158\234\132\254\212\ETB\138\220\189a2\232K\128\SOH[\DC4\228\242  \209A\161\219\179\223(ty\FS$!{(\230\DC4V\184~\133>\255|\RS,\231"

pubKeyLeader, pubKeyFollower, pubKeyClient :: PublicKey
pubKeyLeader = toPublicKey privKeyLeader
pubKeyFollower = toPublicKey privKeyFollower
pubKeyClient = toPublicKey privKeyClient

keySet :: KeySet
keySet = KeySet
  { _ksCluster = Map.fromList [(nodeIdLeader, pubKeyLeader),(nodeIdFollower, pubKeyFollower)]
  , _ksClient = Map.fromList [(nodeIdClient, pubKeyClient)] }


-- #####################################
-- Commands, with and without provenance
-- #####################################
cmdRPC1, cmdRPC2, cmdRPC1', cmdRPC2', cmdRpc1Received :: Command
cmdRPC1 = Command
  { _cmdEntry = CommandEntry "CreateAccount foo"
  , _cmdClientId = nodeIdClient
  , _cmdRequestId = RequestId 0
  , _cmdProvenance = NewMsg }
cmdRPC2 = Command
  { _cmdEntry = CommandEntry "CreateAccount foo"
  , _cmdClientId = nodeIdClient
  , _cmdRequestId = RequestId 1
  , _cmdProvenance = NewMsg }
cmdRPC1' = (\(Right v) -> v) $ fromWire defaultReceivedAt keySet cmdSignedRPC1
cmdRPC2' = (\(Right v) -> v) $ fromWire defaultReceivedAt keySet cmdSignedRPC2
cmdRpc1Received = Command
  { _cmdEntry = CommandEntry "CreateAccount foo"
  , _cmdClientId = nodeIdClient
  , _cmdRequestId = RequestId 0
  , _cmdProvenance = ReceivedMsg {_pDig = Digest {_digNodeId = NodeID {_host = "localhost", _port = 10002}, _digSig = Signature {unSignature = "G\204\&6\242\t%\186\US*2\ENQ\146\218\235\ESCf!\138\211\204\EOT\227!\182tH',\215\ENQI\DC1\143\187N.\187\SYNi\DC2\154\234\130\249\237\193Uk\ETB\SUB)b\143\&0M_\188\137\158\"\\\212\132\ACK"}, _digPubkey = PublicKey {unPublicKey = "[\DC4\228\242  \209A\161\219\179\223(ty\FS$!{(\230\DC4V\184~\133>\255|\RS,\231"}, _digType = CMD}, _pOrig = "\NUL\NUL\NUL\NUL\NUL\NUL\NUL\DC1CreateAccount foo\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL", _pTimeStamp = defaultReceivedAt}}

cmdSignedRPC1, cmdSignedRPC2 :: SignedRPC
--cmdSignedRPC1 = toWire nodeIdClient pubKeyClient privKeyClient cmdRPC1
cmdSignedRPC1 = SignedRPC {_sigDigest = Digest {_digNodeId = NodeID {_host = "localhost", _port = 10002}, _digSig = Signature {unSignature = "G\204\&6\242\t%\186\US*2\ENQ\146\218\235\ESCf!\138\211\204\EOT\227!\182tH',\215\ENQI\DC1\143\187N.\187\SYNi\DC2\154\234\130\249\237\193Uk\ETB\SUB)b\143\&0M_\188\137\158\"\\\212\132\ACK"}, _digPubkey = PublicKey {unPublicKey = "[\DC4\228\242  \209A\161\219\179\223(ty\FS$!{(\230\DC4V\184~\133>\255|\RS,\231"}, _digType = CMD}, _sigBody = "\NUL\NUL\NUL\NUL\NUL\NUL\NUL\DC1CreateAccount foo\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL"}
--cmdSignedRPC2 = toWire nodeIdClient pubKeyClient privKeyClient cmdRPC2
cmdSignedRPC2 = SignedRPC {_sigDigest = Digest {_digNodeId = NodeID {_host = "localhost", _port = 10002}, _digSig = Signature {unSignature = "\a\235]\148\227\216\NULd]\DC1[\221\169\218ql\241\134\204\&2\197\&5@\189\211\151\192\176\169\207\"\179\250\&6M\212\174\175\168\132)\n(\NAK\207\180R!\178\ETXRM\248?\DC3\137Ez\190\SO\229\164\t\ETX"}, _digPubkey = PublicKey {unPublicKey = "[\DC4\228\242  \209A\161\219\179\223(ty\FS$!{(\230\DC4V\184~\133>\255|\RS,\231"}, _digType = CMD}, _sigBody = "\NUL\NUL\NUL\NUL\NUL\NUL\NUL\DC1CreateAccount foo\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL\SOH"}

cmdSignedRpc1BS :: ByteString
-- cmdSignedRpc1BS = encode cmdSignedRPC1
cmdSignedRpc1BS = "\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL@G\204\&6\242\t%\186\US*2\ENQ\146\218\235\ESCf!\138\211\204\EOT\227!\182tH',\215\ENQI\DC1\143\187N.\187\SYNi\DC2\154\234\130\249\237\193Uk\ETB\SUB)b\143\&0M_\188\137\158\"\\\212\132\ACK\NUL\NUL\NUL\NUL\NUL\NUL\NUL [\DC4\228\242  \209A\161\219\179\223(ty\FS$!{(\230\DC4V\184~\133>\255|\RS,\231\EOT\NUL\NUL\NUL\NUL\NUL\NUL\NUL:\NUL\NUL\NUL\NUL\NUL\NUL\NUL\DC1CreateAccount foo\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL"

-- #############################################
-- CommandResponse, with and without provenance
-- #############################################
cmdrRPC :: CommandResponse
cmdrRPC = CommandResponse
  { _cmdrResult     = CommandResult "account created: foo"
  , _cmdrLeaderId   = nodeIdLeader
  , _cmdrNodeId     = nodeIdLeader
  , _cmdrRequestId  = RequestId 1
  , _cmdrProvenance = NewMsg
  }

cmdrSignedRPC :: SignedRPC
cmdrSignedRPC = toWire nodeIdLeader pubKeyLeader privKeyLeader cmdrRPC

-- ########################################################
-- LogEntry(s) and Seq LogEntry with correct hashes.
-- LogEntry is not an RPC but is(are) nested in other RPCs.
-- Given this, they are handled differently (no provenance)
-- ########################################################
logEntry1, logEntry2 :: LogEntry
logEntry1 = LogEntry
  { _leTerm    = Term 0
  , _leCommand = cmdRPC1'
  , _leHash    = "\237\157D\GS\158k\214\188\219.,\248\226\232\174\227\228\236R\t\189\&3v\NUL\255\&5\224\&4|\178\STX\252"
  }
logEntry2 = LogEntry
  { _leTerm    = Term 0
  , _leCommand = cmdRPC2'
  , _leHash    = "\244\136\187c\222\164\131\178;D)M\DEL\142|\251Kv\213\186\247q;3`\194\227O\US\223Q\157"
  }

leSeq, leSeqDecoded :: Seq LogEntry
leSeq = Seq.fromList [logEntry1, logEntry2]
leSeqDecoded = (\(Right v) -> v) $ decodeLEWire defaultReceivedAt keySet leWire

leWire :: [LEWire]
leWire = encodeLEWire nodeIdLeader pubKeyLeader privKeyLeader leSeq

-- ################################################
-- RequestVoteResponse, with and without provenance
-- ################################################

rvrRPC1, rvrRPC2 :: RequestVoteResponse
rvrRPC1 = RequestVoteResponse
  { _rvrTerm        = Term 0
  , _rvrCurLogIndex = LogIndex (-1)
  , _rvrNodeId      = nodeIdLeader
  , _voteGranted    = True
  , _rvrCandidateId = nodeIdLeader
  , _rvrProvenance  = NewMsg
  }
rvrRPC2 = RequestVoteResponse
  { _rvrTerm        = Term 0
  , _rvrCurLogIndex = LogIndex (-1)
  , _rvrNodeId      = nodeIdFollower
  , _voteGranted    = True
  , _rvrCandidateId = nodeIdLeader
  , _rvrProvenance  = NewMsg
  }

rvrSignedRPC1, rvrSignedRPC2 :: SignedRPC
rvrSignedRPC1 = toWire nodeIdLeader pubKeyLeader privKeyLeader rvrRPC1
rvrSignedRPC2 = toWire nodeIdFollower pubKeyFollower privKeyFollower rvrRPC2

rvrRPC1', rvrRPC2' :: RequestVoteResponse
rvrRPC1' = (\(Right v) -> v) $ fromWire defaultReceivedAt keySet rvrSignedRPC1
rvrRPC2' = (\(Right v) -> v) $ fromWire defaultReceivedAt keySet rvrSignedRPC2

rvrRPCSet' :: Set RequestVoteResponse
rvrRPCSet' = Set.fromList [rvrRPC1', rvrRPC2']

rvrSignedRPCList :: [SignedRPC]
rvrSignedRPCList = [rvrSignedRPC1, rvrSignedRPC2]

-- #############################################
-- AppendEntries, with and without provenance
-- #############################################
aeRPC, aeRpcReceived, aeEmptyRPC, aeEmptyRpcReceived :: AppendEntries
aeRPC = AppendEntries
  { _aeTerm        = Term 0
  , _leaderId      = nodeIdLeader
  , _prevLogIndex  = LogIndex (-1)
  , _prevLogTerm   = Term 0
  , _aeEntries     = leSeq
  , _aeQuorumVotes = rvrRPCSet'
  , _aeProvenance  = NewMsg
  }
aeEmptyRPC = AppendEntries
  { _aeTerm        = Term 0
  , _leaderId      = nodeIdLeader
  , _prevLogIndex  = LogIndex (-1)
  , _prevLogTerm   = Term 0
  , _aeEntries     = Seq.empty
  , _aeQuorumVotes = Set.empty
  , _aeProvenance  = NewMsg
  }
-- aeRpcReceived = (\(Right v) -> v :: AppendEntries) $ fromWire defaultReceivedAt keySet aeSignedRPC
aeRpcReceived = AppendEntries
  {_aeTerm = Term 0
  , _leaderId = NodeID {_host = "localhost", _port = 10000}
  , _prevLogIndex = LogIndex (-1)
  , _prevLogTerm = Term 0
  , _aeEntries = leSeq
  , _aeQuorumVotes = rvrRPCSet'
  , _aeProvenance = ReceivedMsg {_pDig = Digest {_digNodeId = NodeID {_host = "localhost", _port = 10000}, _digSig = Signature {unSignature = "\EOT\153`\254\180\&4\FSHa\130\194\172\226;\198\241\DC3@\129\FSm\133?\132\157\146\&9L\199l\169\184\223\SUB#\254\168\\\183\163{w@\197y\228K:\243\133*\223^\EMf\177\rkTo\187\DC4\217\ETX"}, _digPubkey = PublicKey {unPublicKey = "\199\NAK\238\171\\\161\222\247\186/\DC3\204Qqd\225}\202\150e~q\255;\223\233\211:\211\SUBT\145"}, _digType = AE}, _pOrig = "\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\STX\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL@G\204\&6\242\t%\186\US*2\ENQ\146\218\235\ESCf!\138\211\204\EOT\227!\182tH',\215\ENQI\DC1\143\187N.\187\SYNi\DC2\154\234\130\249\237\193Uk\ETB\SUB)b\143\&0M_\188\137\158\"\\\212\132\ACK\NUL\NUL\NUL\NUL\NUL\NUL\NUL [\DC4\228\242  \209A\161\219\179\223(ty\FS$!{(\230\DC4V\184~\133>\255|\RS,\231\EOT\NUL\NUL\NUL\NUL\NUL\NUL\NUL:\NUL\NUL\NUL\NUL\NUL\NUL\NUL\DC1CreateAccount foo\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL \237\157D\GS\158k\214\188\219.,\248\226\232\174\227\228\236R\t\189\&3v\NUL\255\&5\224\&4|\178\STX\252\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL@\a\235]\148\227\216\NULd]\DC1[\221\169\218ql\241\134\204\&2\197\&5@\189\211\151\192\176\169\207\"\179\250\&6M\212\174\175\168\132)\n(\NAK\207\180R!\178\ETXRM\248?\DC3\137Ez\190\SO\229\164\t\ETX\NUL\NUL\NUL\NUL\NUL\NUL\NUL [\DC4\228\242  \209A\161\219\179\223(ty\FS$!{(\230\DC4V\184~\133>\255|\RS,\231\EOT\NUL\NUL\NUL\NUL\NUL\NUL\NUL:\NUL\NUL\NUL\NUL\NUL\NUL\NUL\DC1CreateAccount foo\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL \244\136\187c\222\164\131\178;D)M\DEL\142|\251Kv\213\186\247q;3`\194\227O\US\223Q\157\NUL\NUL\NUL\NUL\NUL\NUL\NUL\STX\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\NUL\NUL\NUL\NUL\NUL\NUL\NUL@\128\&1\168p^\140Os\132b\EOTe\DC1F\a[\US\239\r\210`BMw\DLE\239\ENQ\236\221\NAKp\144#\220\138:-\138\195\&2L&|KZk\133a\184\NAKo\149\185\218\195B\161\166\155\DC1s\193\210\ENQ\NUL\NUL\NUL\NUL\NUL\NUL\NUL \199\NAK\238\171\\\161\222\247\186/\DC3\204Qqd\225}\202\150e~q\255;\223\233\211:\211\SUBT\145\ETX\NUL\NUL\NUL\NUL\NUL\NUL\NULC\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC1\NUL\NUL\NUL\NUL\NUL\NUL\NUL@u\224\155P\133\216\198\161\&1\160\&9\189R\134}\173{\237t\239\a>?\190\250?\232\140\161\228\164\209g\150\CAN\210\207\255Ll,\195\162Hd\166)\137\150\228F*\tz\154cu\218\198\224\222m\STX\t\NUL\NUL\NUL\NUL\NUL\NUL\NUL \164}\DC2`\245Bh-Mj!\227\220A\EOTfN\129\&5\213Z\ENQ\155\129\155d\SUB\129\194&\SUB4\ETX\NUL\NUL\NUL\NUL\NUL\NUL\NULC\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC1\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE", _pTimeStamp = defaultReceivedAt}}
aeEmptyRpcReceived = AppendEntries
  { _aeTerm = Term 0
  , _leaderId = NodeID {_host = "localhost", _port = 10000}
  , _prevLogIndex = LogIndex (-1)
  , _prevLogTerm = Term 0
  , _aeEntries = Seq.empty
  , _aeQuorumVotes = Set.empty
  , _aeProvenance = ReceivedMsg {_pDig = Digest {_digNodeId = NodeID {_host = "localhost", _port = 10000}, _digSig = Signature {unSignature = "e\206\214?\v\DC3nr\184\SUB\191\236\136\225\142Rm\146X\146=\131\144W\169\231\EMo\f\206\175\143\US\220Ny\FS`V\217\182\176\216\245\179\247\147\NAK\221\EOT\180\231@.\EOT\184:!5A\128\160\151\SOH"}, _digPubkey = PublicKey {unPublicKey = "\199\NAK\238\171\\\161\222\247\186/\DC3\204Qqd\225}\202\150e~q\255;\223\233\211:\211\SUBT\145"}, _digType = AE}, _pOrig = "\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL", _pTimeStamp = defaultReceivedAt}}

aeSignedRPC, aeEmptySignedRPC :: SignedRPC
-- aeSignedRPC = toWire nodeIdLeader pubKeyLeader privKeyLeader aeRPC
aeSignedRPC = SignedRPC {_sigDigest = Digest {_digNodeId = NodeID {_host = "localhost", _port = 10000}, _digSig = Signature {unSignature = "\EOT\153`\254\180\&4\FSHa\130\194\172\226;\198\241\DC3@\129\FSm\133?\132\157\146\&9L\199l\169\184\223\SUB#\254\168\\\183\163{w@\197y\228K:\243\133*\223^\EMf\177\rkTo\187\DC4\217\ETX"}, _digPubkey = PublicKey {unPublicKey = "\199\NAK\238\171\\\161\222\247\186/\DC3\204Qqd\225}\202\150e~q\255;\223\233\211:\211\SUBT\145"}, _digType = AE}, _sigBody = "\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\STX\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL@G\204\&6\242\t%\186\US*2\ENQ\146\218\235\ESCf!\138\211\204\EOT\227!\182tH',\215\ENQI\DC1\143\187N.\187\SYNi\DC2\154\234\130\249\237\193Uk\ETB\SUB)b\143\&0M_\188\137\158\"\\\212\132\ACK\NUL\NUL\NUL\NUL\NUL\NUL\NUL [\DC4\228\242  \209A\161\219\179\223(ty\FS$!{(\230\DC4V\184~\133>\255|\RS,\231\EOT\NUL\NUL\NUL\NUL\NUL\NUL\NUL:\NUL\NUL\NUL\NUL\NUL\NUL\NUL\DC1CreateAccount foo\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL \237\157D\GS\158k\214\188\219.,\248\226\232\174\227\228\236R\t\189\&3v\NUL\255\&5\224\&4|\178\STX\252\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL@\a\235]\148\227\216\NULd]\DC1[\221\169\218ql\241\134\204\&2\197\&5@\189\211\151\192\176\169\207\"\179\250\&6M\212\174\175\168\132)\n(\NAK\207\180R!\178\ETXRM\248?\DC3\137Ez\190\SO\229\164\t\ETX\NUL\NUL\NUL\NUL\NUL\NUL\NUL [\DC4\228\242  \209A\161\219\179\223(ty\FS$!{(\230\DC4V\184~\133>\255|\RS,\231\EOT\NUL\NUL\NUL\NUL\NUL\NUL\NUL:\NUL\NUL\NUL\NUL\NUL\NUL\NUL\DC1CreateAccount foo\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL \244\136\187c\222\164\131\178;D)M\DEL\142|\251Kv\213\186\247q;3`\194\227O\US\223Q\157\NUL\NUL\NUL\NUL\NUL\NUL\NUL\STX\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\NUL\NUL\NUL\NUL\NUL\NUL\NUL@\128\&1\168p^\140Os\132b\EOTe\DC1F\a[\US\239\r\210`BMw\DLE\239\ENQ\236\221\NAKp\144#\220\138:-\138\195\&2L&|KZk\133a\184\NAKo\149\185\218\195B\161\166\155\DC1s\193\210\ENQ\NUL\NUL\NUL\NUL\NUL\NUL\NUL \199\NAK\238\171\\\161\222\247\186/\DC3\204Qqd\225}\202\150e~q\255;\223\233\211:\211\SUBT\145\ETX\NUL\NUL\NUL\NUL\NUL\NUL\NULC\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC1\NUL\NUL\NUL\NUL\NUL\NUL\NUL@u\224\155P\133\216\198\161\&1\160\&9\189R\134}\173{\237t\239\a>?\190\250?\232\140\161\228\164\209g\150\CAN\210\207\255Ll,\195\162Hd\166)\137\150\228F*\tz\154cu\218\198\224\222m\STX\t\NUL\NUL\NUL\NUL\NUL\NUL\NUL \164}\DC2`\245Bh-Mj!\227\220A\EOTfN\129\&5\213Z\ENQ\155\129\155d\SUB\129\194&\SUB4\ETX\NUL\NUL\NUL\NUL\NUL\NUL\NULC\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC1\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE"}
-- aeEmptySignedRPC = toWire nodeIdLeader pubKeyLeader privKeyLeader aeEmptyRPC
aeEmptySignedRPC = SignedRPC {_sigDigest = Digest {_digNodeId = NodeID {_host = "localhost", _port = 10000}, _digSig = Signature {unSignature = "e\206\214?\v\DC3nr\184\SUB\191\236\136\225\142Rm\146X\146=\131\144W\169\231\EMo\f\206\175\143\US\220Ny\FS`V\217\182\176\216\245\179\247\147\NAK\221\EOT\180\231@.\EOT\184:!5A\128\160\151\SOH"}, _digPubkey = PublicKey {unPublicKey = "\199\NAK\238\171\\\161\222\247\186/\DC3\204Qqd\225}\202\150e~q\255;\223\233\211:\211\SUBT\145"}, _digType = AE}, _sigBody = "\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL"}

aeSignedRpcBS, aeEmptySignedRpcBS :: ByteString
aeSignedRpcBS = "\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\NUL\NUL\NUL\NUL\NUL\NUL\NUL@\EOT\153`\254\180\&4\FSHa\130\194\172\226;\198\241\DC3@\129\FSm\133?\132\157\146\&9L\199l\169\184\223\SUB#\254\168\\\183\163{w@\197y\228K:\243\133*\223^\EMf\177\rkTo\187\DC4\217\ETX\NUL\NUL\NUL\NUL\NUL\NUL\NUL \199\NAK\238\171\\\161\222\247\186/\DC3\204Qqd\225}\202\150e~q\255;\223\233\211:\211\SUBT\145\NUL\NUL\NUL\NUL\NUL\NUL\NUL\ETX\227\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\STX\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL@G\204\&6\242\t%\186\US*2\ENQ\146\218\235\ESCf!\138\211\204\EOT\227!\182tH',\215\ENQI\DC1\143\187N.\187\SYNi\DC2\154\234\130\249\237\193Uk\ETB\SUB)b\143\&0M_\188\137\158\"\\\212\132\ACK\NUL\NUL\NUL\NUL\NUL\NUL\NUL [\DC4\228\242  \209A\161\219\179\223(ty\FS$!{(\230\DC4V\184~\133>\255|\RS,\231\EOT\NUL\NUL\NUL\NUL\NUL\NUL\NUL:\NUL\NUL\NUL\NUL\NUL\NUL\NUL\DC1CreateAccount foo\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL \237\157D\GS\158k\214\188\219.,\248\226\232\174\227\228\236R\t\189\&3v\NUL\255\&5\224\&4|\178\STX\252\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL@\a\235]\148\227\216\NULd]\DC1[\221\169\218ql\241\134\204\&2\197\&5@\189\211\151\192\176\169\207\"\179\250\&6M\212\174\175\168\132)\n(\NAK\207\180R!\178\ETXRM\248?\DC3\137Ez\190\SO\229\164\t\ETX\NUL\NUL\NUL\NUL\NUL\NUL\NUL [\DC4\228\242  \209A\161\219\179\223(ty\FS$!{(\230\DC4V\184~\133>\255|\RS,\231\EOT\NUL\NUL\NUL\NUL\NUL\NUL\NUL:\NUL\NUL\NUL\NUL\NUL\NUL\NUL\DC1CreateAccount foo\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL \244\136\187c\222\164\131\178;D)M\DEL\142|\251Kv\213\186\247q;3`\194\227O\US\223Q\157\NUL\NUL\NUL\NUL\NUL\NUL\NUL\STX\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\NUL\NUL\NUL\NUL\NUL\NUL\NUL@\128\&1\168p^\140Os\132b\EOTe\DC1F\a[\US\239\r\210`BMw\DLE\239\ENQ\236\221\NAKp\144#\220\138:-\138\195\&2L&|KZk\133a\184\NAKo\149\185\218\195B\161\166\155\DC1s\193\210\ENQ\NUL\NUL\NUL\NUL\NUL\NUL\NUL \199\NAK\238\171\\\161\222\247\186/\DC3\204Qqd\225}\202\150e~q\255;\223\233\211:\211\SUBT\145\ETX\NUL\NUL\NUL\NUL\NUL\NUL\NULC\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC1\NUL\NUL\NUL\NUL\NUL\NUL\NUL@u\224\155P\133\216\198\161\&1\160\&9\189R\134}\173{\237t\239\a>?\190\250?\232\140\161\228\164\209g\150\CAN\210\207\255Ll,\195\162Hd\166)\137\150\228F*\tz\154cu\218\198\224\222m\STX\t\NUL\NUL\NUL\NUL\NUL\NUL\NUL \164}\DC2`\245Bh-Mj!\227\220A\EOTfN\129\&5\213Z\ENQ\155\129\155d\SUB\129\194&\SUB4\ETX\NUL\NUL\NUL\NUL\NUL\NUL\NULC\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC1\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE"
aeEmptySignedRpcBS = "\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\NUL\NUL\NUL\NUL\NUL\NUL\NUL@e\206\214?\v\DC3nr\184\SUB\191\236\136\225\142Rm\146X\146=\131\144W\169\231\EMo\f\206\175\143\US\220Ny\FS`V\217\182\176\216\245\179\247\147\NAK\221\EOT\180\231@.\EOT\184:!5A\128\160\151\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL \199\NAK\238\171\\\161\222\247\186/\DC3\204Qqd\225}\202\150e~q\255;\223\233\211:\211\SUBT\145\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NULA\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL"

aeRPC' :: RequestVoteResponse
aeRPC' = (\(Right v) -> v) $ fromWire defaultReceivedAt keySet aeSignedRPC

-- ## Old Serialization Strategy

data OldAppendEntries = OldAppendEntries
  { _oaeTerm        :: !Term
  , _oleaderId      :: !NodeID
  , _oprevLogIndex  :: !LogIndex
  , _oprevLogTerm   :: !Term
  , _oaeEntries     :: !(Seq LogEntry)
  , _oaeQuorumVotes :: !(Set RequestVoteResponse)
  , _oaeSig  :: !Signature
  }
  deriving (Show, Eq, Generic)

instance Serialize OldAppendEntries

oaeRPC, oaeRPC', oaeEmptyRPC, oaeEmptyRPC' :: OldAppendEntries
oaeRPC = OldAppendEntries
  { _oaeTerm        = Term 0
  , _oleaderId      = nodeIdLeader
  , _oprevLogIndex  = LogIndex (-1)
  , _oprevLogTerm   = Term 0
  , _oaeEntries     = leSeq
  , _oaeQuorumVotes = rvrRPCSet'
  , _oaeSig  = (Signature "")
  }
oaeEmptyRPC = OldAppendEntries
  { _oaeTerm        = Term 0
  , _oleaderId      = nodeIdLeader
  , _oprevLogIndex  = LogIndex (-1)
  , _oprevLogTerm   = Term 0
  , _oaeEntries     = Seq.empty
  , _oaeQuorumVotes = rvrRPCSet'
  , _oaeSig  = Signature ""
  }
oaeRPC' = OldAppendEntries
  { _oaeTerm        = Term 0
  , _oleaderId      = nodeIdLeader
  , _oprevLogIndex  = LogIndex (-1)
  , _oprevLogTerm   = Term 0
  , _oaeEntries     = leSeq
  , _oaeQuorumVotes = rvrRPCSet'
  , _oaeSig  = Signature {unSignature = "\166\EOT/G\233LK\225\130y:\149\143\209\134ep\EOT\SO\248\254\SUB\f\244:on\253o\a\225\236\192\221\186\FS\217\161\146\148\132\176d@\161\201@\145\174\179z\192\135z\195\182u3\129J\184yU\r"}
  }
oaeEmptyRPC' = OldAppendEntries
  { _oaeTerm        = Term 0
  , _oleaderId      = nodeIdLeader
  , _oprevLogIndex  = LogIndex (-1)
  , _oprevLogTerm   = Term 0
  , _oaeEntries     = Seq.empty
  , _oaeQuorumVotes = rvrRPCSet'
  , _oaeSig  = Signature {unSignature = "%\254\ENQ*\233\206h\222\186\\\ENQ\f\202\128\215\142\175\222\203 \nb\152%\238\151\250K}\247T\217\149\179\201a^\184\"\207\172\ACKx\198\181]R~W\163\149w\214cp\251\236\234c\239\255A\176\a"}
  }

oaeSerRPC, oaeEmptySerRPC :: ByteString
oaeSerRPC = "\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\STX\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\DC1CreateAccount foo\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL@G\204\&6\242\t%\186\US*2\ENQ\146\218\235\ESCf!\138\211\204\EOT\227!\182tH',\215\ENQI\DC1\143\187N.\187\SYNi\DC2\154\234\130\249\237\193Uk\ETB\SUB)b\143\&0M_\188\137\158\"\\\212\132\ACK\NUL\NUL\NUL\NUL\NUL\NUL\NUL [\DC4\228\242  \209A\161\219\179\223(ty\FS$!{(\230\DC4V\184~\133>\255|\RS,\231\EOT\NUL\NUL\NUL\NUL\NUL\NUL\NUL:\NUL\NUL\NUL\NUL\NUL\NUL\NUL\DC1CreateAccount foo\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL \237\157D\GS\158k\214\188\219.,\248\226\232\174\227\228\236R\t\189\&3v\NUL\255\&5\224\&4|\178\STX\252\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\DC1CreateAccount foo\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL\SOH\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL@\a\235]\148\227\216\NULd]\DC1[\221\169\218ql\241\134\204\&2\197\&5@\189\211\151\192\176\169\207\"\179\250\&6M\212\174\175\168\132)\n(\NAK\207\180R!\178\ETXRM\248?\DC3\137Ez\190\SO\229\164\t\ETX\NUL\NUL\NUL\NUL\NUL\NUL\NUL [\DC4\228\242  \209A\161\219\179\223(ty\FS$!{(\230\DC4V\184~\133>\255|\RS,\231\EOT\NUL\NUL\NUL\NUL\NUL\NUL\NUL:\NUL\NUL\NUL\NUL\NUL\NUL\NUL\DC1CreateAccount foo\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL \244\136\187c\222\164\131\178;D)M\DEL\142|\251Kv\213\186\247q;3`\194\227O\US\223Q\157\NUL\NUL\NUL\NUL\NUL\NUL\NUL\STX\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\NUL\NUL\NUL\NUL\NUL\NUL\NUL@\128\&1\168p^\140Os\132b\EOTe\DC1F\a[\US\239\r\210`BMw\DLE\239\ENQ\236\221\NAKp\144#\220\138:-\138\195\&2L&|KZk\133a\184\NAKo\149\185\218\195B\161\166\155\DC1s\193\210\ENQ\NUL\NUL\NUL\NUL\NUL\NUL\NUL \199\NAK\238\171\\\161\222\247\186/\DC3\204Qqd\225}\202\150e~q\255;\223\233\211:\211\SUBT\145\ETX\NUL\NUL\NUL\NUL\NUL\NUL\NULC\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC1\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC1\NUL\NUL\NUL\NUL\NUL\NUL\NUL@u\224\155P\133\216\198\161\&1\160\&9\189R\134}\173{\237t\239\a>?\190\250?\232\140\161\228\164\209g\150\CAN\210\207\255Ll,\195\162Hd\166)\137\150\228F*\tz\154cu\218\198\224\222m\STX\t\NUL\NUL\NUL\NUL\NUL\NUL\NUL \164}\DC2`\245Bh-Mj!\227\220A\EOTfN\129\&5\213Z\ENQ\155\129\155d\SUB\129\194&\SUB4\ETX\NUL\NUL\NUL\NUL\NUL\NUL\NULC\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC1\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL@\166\EOT/G\233LK\225\130y:\149\143\209\134ep\EOT\SO\248\254\SUB\f\244:on\253o\a\225\236\192\221\186\FS\217\161\146\148\132\176d@\161\201@\145\174\179z\192\135z\195\182u3\129J\184yU\r"
oaeEmptySerRPC = "\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\STX\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\NUL\NUL\NUL\NUL\NUL\NUL\NUL@\128\&1\168p^\140Os\132b\EOTe\DC1F\a[\US\239\r\210`BMw\DLE\239\ENQ\236\221\NAKp\144#\220\138:-\138\195\&2L&|KZk\133a\184\NAKo\149\185\218\195B\161\166\155\DC1s\193\210\ENQ\NUL\NUL\NUL\NUL\NUL\NUL\NUL \199\NAK\238\171\\\161\222\247\186/\DC3\204Qqd\225}\202\150e~q\255;\223\233\211:\211\SUBT\145\ETX\NUL\NUL\NUL\NUL\NUL\NUL\NULC\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC1\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC1\NUL\NUL\NUL\NUL\NUL\NUL\NUL@u\224\155P\133\216\198\161\&1\160\&9\189R\134}\173{\237t\239\a>?\190\250?\232\140\161\228\164\209g\150\CAN\210\207\255Ll,\195\162Hd\166)\137\150\228F*\tz\154cu\218\198\224\222m\STX\t\NUL\NUL\NUL\NUL\NUL\NUL\NUL \164}\DC2`\245Bh-Mj!\227\220A\EOTfN\129\&5\213Z\ENQ\155\129\155d\SUB\129\194&\SUB4\ETX\NUL\NUL\NUL\NUL\NUL\NUL\NULC\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\255\255\255\255\255\255\255\255\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC1\SOH\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DLE\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL@%\254\ENQ*\233\206h\222\186\\\ENQ\f\202\128\215\142\175\222\203 \nb\152%\238\151\250K}\247T\217\149\179\201a^\184\"\207\172\ACKx\198\181]R~W\163\149w\214cp\251\236\234c\239\255A\176\a"

oldAeSign :: OldAppendEntries -> OldAppendEntries
oldAeSign oae = oae {_oaeSig = dsign privKeyLeader (encode $ oae {_oaeSig = Signature ""})}

oldAeVerify :: OldAppendEntries -> Bool
oldAeVerify oae = case Map.lookup nodeIdLeader $ _ksCluster keySet of
  Nothing -> False
  Just k -> dverify k (encode $ oae {_oaeSig = Signature ""}) (_oaeSig oae)

oldAeEncode :: OldAppendEntries -> ByteString
oldAeEncode oae = encode $ oldAeSign oae

oldAeDecode :: ByteString -> OldAppendEntries
oldAeDecode bs = case decode bs of
  Left err -> error err
  Right v -> if oldAeVerify v
             then v
             else error "Failed to verify"

data OldCommand = OldCommand
  { _ocmdEntry      :: !CommandEntry
  , _ocmdClientId   :: !NodeID
  , _ocmdRequestId  :: !RequestId
  , _ocmdSig :: !Signature
  }
  deriving (Show, Eq, Generic)
instance Serialize OldCommand -- again, for SQLite

data MsgType' = ClientMsg | ClusterMsg -- this is to replicate the casing behavior of the old system

ocmdRPC, ocmdSignedRPC :: OldCommand
ocmdRPC = OldCommand
  { _ocmdEntry = CommandEntry "CreateAccount foo"
  , _ocmdClientId = nodeIdClient
  , _ocmdRequestId = RequestId 0
  , _ocmdSig = Signature "" }
ocmdSignedRPC = OldCommand
  { _ocmdEntry = CommandEntry "CreateAccount foo"
  , _ocmdClientId = nodeIdClient
  , _ocmdRequestId = RequestId 0
  , _ocmdSig = Signature "\NUL\NUL8]]5\200z\"\ACK#\202\217\214\194\189Zi\192\219\158ho\194\ENQ-5\182\SI\DEL\144\DC2\149\128h\EMG]7\155\165\195\172\&1\137: \155/\190Ca\RS\v\198R<f\227:|\202\160\ENQ"}

ocmdSerRPC :: ByteString
ocmdSerRPC = "\NUL\NUL\NUL\NUL\NUL\NUL\NUL\DC1CreateAccount foo\NUL\NUL\NUL\NUL\NUL\NUL\NUL\tlocalhost\NUL\NUL\NUL\NUL\NUL\NUL'\DC2\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL\NUL@\NUL\NUL8]]5\200z\"\ACK#\202\217\214\194\189Zi\192\219\158ho\194\ENQ-5\182\SI\DEL\144\DC2\149\128h\EMG]7\155\165\195\172\&1\137: \155/\190Ca\RS\v\198R<f\227:|\202\160\ENQ"

oldCmdSign :: OldCommand -> OldCommand
oldCmdSign ocmd = ocmd {_ocmdSig = dsign privKeyClient (encode $ ocmd {_ocmdSig = Signature ""})}

oldCmdVerify :: MsgType' -> KeySet -> OldCommand -> Either String Bool
oldCmdVerify ClusterMsg ks ocmd = case Map.lookup (_ocmdClientId ocmd) $ _ksCluster ks of
  Nothing -> Left $ "Key for node not found: " ++ (show $ _ocmdClientId ocmd)
  Just k -> Right $ dverify k (encode $ ocmd {_ocmdSig = Signature ""}) (_ocmdSig ocmd)
oldCmdVerify ClientMsg ks ocmd = case Map.lookup (_ocmdClientId ocmd)$ _ksClient ks of
  Nothing -> Left $ "Key for node not found: " ++ (show $ _ocmdClientId ocmd)
  Just k -> Right $ dverify k (encode $ ocmd {_ocmdSig = Signature ""}) (_ocmdSig ocmd)

oldCmdEncode :: OldCommand -> ByteString
oldCmdEncode ocmd = encode $ oldCmdSign ocmd

oldCmdDecode :: MsgType' -> KeySet -> ByteString -> Either String OldCommand
oldCmdDecode msgType ks bs = case decode bs of
  Left err -> error err
  Right v -> case oldCmdVerify msgType ks v of
    Left err -> Left err
    Right b -> if b
               then Right v
               else Left "Failed to verify"

-- ############################
-- #### CBOR Serialisation ####
-- ############################

cmdSignedRpcCBOR :: SignedRPC
cmdSignedRpcCBOR = SignedRPC
  { _sigDigest = Digest
    { _digNodeId = nodeIdClient
    , _digSig = Signature "DD\206\DLE\131\158!Lo!\193\212\162\215\a\176\&7\234\170\DEL\185\159{\CANk\249\247t2\183B\160\248\&7\176\205\164\129\155\232\198)a?FH\134^\215\SO\EOT\161\229\EM\196/_6\232\191\187KK\v"
    , _digPubkey = pubKeyClient
    , _digType = CMD}
  , _sigBody = "\131QCreateAccount foo\130ilocalhost\EM'\DC2\NUL"}

cmdSignedRpcCborBS :: LB.ByteString
cmdSignedRpcCborBS = "\130\132\130ilocalhost\EM'\DC2X@DD\206\DLE\131\158!Lo!\193\212\162\215\a\176\&7\234\170\DEL\185\159{\CANk\249\247t2\183B\160\248\&7\176\205\164\129\155\232\198)a?FH\134^\215\SO\EOT\161\229\EM\196/_6\232\191\187KK\vX [\DC4\228\242  \209A\161\219\179\223(ty\FS$!{(\230\DC4V\184~\133>\255|\RS,\231\EOTX\"\131QCreateAccount foo\130ilocalhost\EM'\DC2\NUL"

class WireFormatCBOR a where
  toWireCBOR   :: NodeID -> PublicKey -> SecretKey -> a -> SignedRPC
  fromWireCBOR :: ReceivedAt -> KeySet -> SignedRPC -> Either String a

instance CBC.Serialise NodeID where
  encode (NodeID h p) = CBE.encodeListLen 2 <> CBC.encode h <> CBC.encode p
  decode = do
    CBD.decodeListLenOf 2
    !h <- CBC.decode
    !p <- CBC.decode
    return $ NodeID h p
instance CBC.Serialise CMDWire where
  encode (CMDWire (c,n,r)) = CBE.encodeListLen 3 <> CBC.encode c <> CBC.encode n <> CBC.encode r
  decode = do
    CBD.decodeListLenOf 3
    !c <- CBC.decode
    !n <- CBC.decode
    !r <- CBC.decode
    return $ CMDWire (c,n,r)
instance CBC.Serialise Signature where
  encode (Signature b) = CBC.encode b
  decode = do
    !b <- CBC.decode
    return $ Signature b
instance CBC.Serialise PublicKey where
  encode (PublicKey b) = CBC.encode b
  decode = do
    !b <- CBC.decode
    return $ PublicKey b
instance CBC.Serialise MsgType where
  encode AE = CBC.encode (0::Word8)
  encode AER = CBC.encode (1::Word8)
  encode RV = CBC.encode (2::Word8)
  encode RVR = CBC.encode (3::Word8)
  encode CMD = CBC.encode (4::Word8)
  encode CMDR = CBC.encode (5::Word8)
  encode REV = CBC.encode (6::Word8)
  decode = do
    !(v :: Word8) <- CBC.decode
    case v of
      0 -> return AE
      1 -> return AER
      2 -> return RV
      3 -> return RVR
      4 -> return CMD
      5 -> return CMDR
      6 -> return REV
      n -> fail $ "Attempting to decode MsgType [0,6] but got " ++ show n

instance CBC.Serialise Digest where
  encode (Digest n s p t) = CBE.encodeListLen 4
                            <> CBC.encode n
                            <> CBC.encode s
                            <> CBC.encode p
                            <> CBC.encode t
  decode = do
    CBD.decodeListLenOf 4
    !n <- CBC.decode
    !s <- CBC.decode
    !p <- CBC.decode
    !t <- CBC.decode
    return $ Digest n s p t
instance CBC.Serialise SignedRPC where
  encode (SignedRPC d b) = CBE.encodeListLen 2
                           <> CBC.encode d
                           <> CBC.encode b
  decode = do
    CBD.decodeListLenOf 2
    !d <- CBC.decode
    !b <- CBC.decode
    return $ SignedRPC d b


instance WireFormatCBOR Command where
  toWireCBOR nid pubKey privKey Command{..} = case _cmdProvenance of
    NewMsg -> let bdy = CBW.toStrictByteString $ CBC.encode $ CMDWire (_cmdEntry, _cmdClientId, _cmdRequestId)
                  sig = dsign privKey bdy
                  dig = Digest nid sig pubKey CMD
              in SignedRPC dig bdy
    ReceivedMsg{..} -> SignedRPC _pDig _pOrig
  fromWireCBOR ts ks s@(SignedRPC dig bdy) = case verifySignedRPC ks s of
    Left err -> Left err
    Right False -> error "Invariant Failure: verification came back as Right False"
    Right True -> if _digType dig /= CMD
      then error $ "Invariant Failure: attempting to decode " ++ show (_digType dig) ++ " with CMDWire instance"
      else case CBR.deserialiseFromBytes CBC.decode $ LB.fromStrict bdy of
        Left err -> Left $ "Failure to decode CMDWire: " ++ err
        Right (CMDWire (ce,nid,rid)) -> Right $ Command ce nid rid $ ReceivedMsg dig bdy ts
  {-# INLINE toWireCBOR #-}
  {-# INLINE fromWireCBOR #-}

-- ###########################
-- #### ED Crypto Version ####
-- ###########################

edPubKey :: Ed.PublicKey
edPubKey = Ed.PublicKey "'\235\193B\217\183\245\236\197&B\142\139\&3\DC1\192\131\131\248\245\151\&1\244\b9>\223\131S\r$\223"

edPrivKey :: Ed.SecretKey
edPrivKey = Ed.SecretKey "\196\242\211Q'\180_\192\166;)\231)\254n=\196\236K\r\SO\SIK\209IM\ESC\DLE\192ut{'\235\193B\217\183\245\236\197&B\142\139\&3\DC1\192\131\131\248\245\151\&1\244\b9>\223\131S\r$\223"

edB256,edB512,edB1024,edB2048,edB4096 :: ByteString
edB256 = "u\ESC\242~\228aW\185\SIg\SOH\224\132tX\148\133F:5//\158\191\193^\161\227\169\207a\212\137\245\224qX\171(\251\SI}\242\249\252^\192&:\195\147#?G%\198\220\247F(\174\229\216\243\163\138$\130.\191\211\221->\128\v\150\146q\152\&9\212\154\160\249\208vt\239\233\DLE.g|4iZ\206\151;\DC1\169W\215\&6\183\235w\176\DLE\EOT3'\247\251\225\180h\DEL\174\204\131\196H\GSf\FS]\203K\220T\207\FS\206;\228A\211\132{Q\226\SUB\DEL\219\243$4\r\155\&3\221\SI7o\229\232\160G\253\157\230,\173\190P\STX\191\NAKod\DC3\215`\ETX\173G\153\SYN\167v\238\184W\171\220\128\138\135H\158\180\199\200\n@~\210\204\251\&9\236z \253:7\ACKf\nZ?<\FS\DC4W?\234\&4\207\239\f\252n}\251\b&\ESC\236\239dei\130P\219\137\212\177z\174\226>\155s@\139\134\228E\207\208\224("
edB512 = "\NUL\243v\SYN\132\DC3\170\228\157\222\175\236i\200\215\197\139xI\230\"\168e)\167\214xi\255\EM4u7\192\143\f\231\255\ETX.\253\223\238\215J\EOTo\\\169]%\152\225B\237\165\167\172\NULD\253\204\189W\ETB\DC4r\148\133D+*\233\228\209(\165\194\211ZF\DC1\147\239\NAK7\255W$\209\209\205w\147\197\155Xev\147\202\209\239&\173\236\144\206\244\181j\250\181V\199\r(\136k>t\134I}\161\144A\246\210{bR\DC2NH6O`J\DEL2\ETB\170v\226&\159\152\FS\FSI\187\226c\185\DC2\f\171o\DEL!^/.\214$\213\151\&4[\160\\U\SI c\STXN\RS\SOH\188<)m\137\166\159\EM\137\177\189\238Nf#\236G\RSHi\175\193\171\EOTu\US\FS\222\179\a\211\&2\200t\187q\237\231d\132\200\DEL\EOT\DC2\246\GS\DLE{w\151\DC1\SUB\205M\205\239\141\ETB_\221\ACKa1\171\\\ETB\DC4`\166\198\135\141\&3\254\NULg\241\225\t\199\214\207\GS\191\227)B#\CAN\225\196\253T%\142]\CAN\SO\t\224\129\SOH\243\182\rW\215K\163\229\195\145\210~R\234\175\241\&5\189q\214&\205\141\154\CAN\191\168\192\ESC\166\ESC\145\129\213\254\&9^\188m\176\144\191\&38\205\179\250zf4R\DEL\t\162\139,\225\174\188\213\217\255|)\FS\186\223%\139\166\198\GSqcZm\169p\209\223:Q\141\ACK<Z\207{\131\163\135\248\138\DC4FU\232\f\f\144\185#\164\224\140\189c\146\242\CAN\231\145#\233h\172B_\DC1:\ETB\216A\227\246\162e\DLE\147\202_\229\236\178N\246or\233>M\173\&0\218\223]\US\169\143\ETX\SI\179X\DC1\210Jb\252$\177s|\"\tv\145v\146\&5\205%Y\DEL\202g\NUL\241xZwJi\134\DC4\242\199;2\193\132l\ETX\EM\221\186v\164\245\229\217\157*\223\174nn:W\175/\228Z\149\US\244\SYN8\ACK\194\132\170\SYN\240\230\144\204\190\201\177\218"
edB1024 = "8\170\130\166\192\n\249\&3U\t-\176\221J .l85\172\131{\197y'V\254d,V\226\175\&22\183\&1\NUL\DC4K\240\183\252\246B^\v\202~Nl\179\143\170\\\138L9S\253\184\233\137\207\212\157b\143\197\165@\238\214N\203V\219a\240\ETBvV\139\143\ENQ5\174\210\140\203$@F\DC2\163dlV\212\140\131\217\162)\218.\243\142\238\169ae\195^\155\194\150\137\149\248\187iVA\232\DC46\197\f\DC1\162\187c\130\"&\180\129\DLE\142\194\DEL\201N].\nXW\CAN6lz~~\175)\190\223\233\242\192!\136$\192\253$c6)`95N\EOT\t,E\143|\252\ENQ\221\201\DLEh\EOTv\151@\162'\234\249<\179\&5\206\ETX%\DLEs\190\212\211\FS$\247\247n\173%9\246\248}\214\195\FS\151 \253\178\153\155y\161\&8xs\170&\189\205\247g\232r\152~\f\SO1w!\DLE\232\&6\243\148\224\DC1\195\130\172t\FSm/\137\161\230\SO\234]\245\143\234\213p\183\SYNuP\130\CAN{\202<4N\236\SI\224\159\204\GSL\ETBj8\GS\251}\208\v<\SI\134r\178cU\210m\240\225/p\DLE\227%JN\207,)k\227\247\207\200=W1\180\DELY\137\RS\210Q>#A\f(z\143\213\155\241\NUL;\168\238\131\a\165\DEL\155T\210z\EM?\f8d\241t\134\ETX\193\187?!|\204\149;\184\134\173\138\244\\\202\CAN]\160\162\245-z_\174 h\150D\144\&8 \DC4\190\188\223s\141\ETX\137[\216\171\156\143\f\183\142\223d\187\177\215\186\&1\237\203e\145&\251\250;\US\247\222\\\194\255\v\ETX\n\236}UF\DC3\237\139;=b\206O{(\GSB\243\190\247\157\144\NAKg\173o\149'\241\226\246\151\154\a\222\230kXn\ETXg\251\&5r^\252\185\NULud\142p`r\247%@]Y\161D\223\EM\171\154sf\133p\180\CAN\200\224p~\214\NAK\186\GS\253\205\230\177\178*\191\192\204\173\196/\128It\207\172\n\251\159aix\EM\225\135\165\210|\179\157q\179\144h\176X\251nD\144knZ\238f\252\163\145\DC3\t\207\&3\f\t\189\229\&7\128\188\rxV\242.\220\192\222JS\220\&46\143\193\152\DLE\158\183\vY\203x\ENQ\235\233\rq\195\215\v\238=\221\170\161\vr9t6\216,YK\205\SOU\213I,\148\&3\190\235\t\250\f\\\243\f\"\235I\142n\NUL:\206\149\241\236\244\&6\135\151b\154&lj\223\STXM\195'\NULir\157\188I\191\239u\206\167\244\134\137+^Z%S\246\144,\161k\"6e|\187l\196\239\209[\194\169\227\128H\176\ETB\r\NAK\246\160!\195\203\&3\217\231\148\159u{\254\137\160\193\237\182\146\168\199\246\FS\188\224\179g\166o\200\218IxD\153+=Fs\145\DEL\NAK\n>Rjm\238\253\142\134+\182\173\DC2\212\156\a2\187T>\224\199\ETB\STX95\240\f z\162,8\165^\129\NUL\171\SOHM\a>\252\167\220\166'\\\176\244\210\FS'/\US'|eC3j\EOT\224f\190v\255\212\US\149\165]\225E;C\229\143\158\219\150\223\197\179\ETB\201\217&s\128qQ\EM\155\198fz\141\182F\158\173\200Id\234;_&9\SUB\169\230\169\&0\162'M\200\182\147\175]W\209\232\242\212\178\148\199C\191p\183\244\173=\149\228y\173p\206\129\225\SI\SOH\215I\tW\128\246m[|'\136\206\222\DC2\n\156\132\192\&4\154/{2\213X\136\&6\219\CAN\248B9v\190z\156th\t\199\DC1\164\159l\f\198\216sZU]*\174A\173~\245\v\129\250\196\STXDuM\SOH\139\174\ny\215\249\ESC\208\142\202\205-69\191\EOT\STX8\170\ETX\ETB\249\178\195\"\176\ENQ\146b4N\187\134\153_G\239<\202\163W\249\175.-H:\183\217\147\233\154\159\225\a\215\SYN\160\248wgh\242\a\164\164M"
edB2048 = "&\158\FS#\EOTWS\169>\133\"\180\NAK\DC4$\n\244\183I\163\147f\155\190\172:\212c\171\EOTH8=\136\167mL\187\194]\249\&0\140wzE\DC3\128\232\144\191\&8\228\221G1C \DC3q\US:\143\246\v\EOT\219=\130\240\199\136\253\168\204\CAN\bs6z\218\DC1\DC4\147v\SUB\253=\243\ETX\172jO\214\251\226\198(\162\131\140\236Y_\234\129\&1-'\132%\237\166\207\206l\135\128f\153\139\r\GS\138\173\213\142\131\232~&\159\236\\\230\DC2\223R\138Z\189\&5\174\235\136\224\252\239\251\155\171P\214v\210\241\242XU!!\227\ETBA\216\243\DC4\229k\143\240v\251]\128\239\DC2\182\192L\130\175B0u\195\203qF\136 =\CAN\154!}c\134{z\135\201\161\199\128\142\CANQ\225T3m?\"\176\172,|\245\255\v\159\191\137\ETX<T\US_\RS\171j\214zU\DC4`\143H\176\155\136C\232\225\n\EOT_\225\190\199\194q5\215\233\v7\226\157g\DC4\142;R\164}3\186\180lG\193\200\218\STX%\187\136\"q\NAK\217\DC2!\ETB[K\231S\251\178>07\142\SID\247=\251\SYN`\183\FS\129Cd'\250(2^#?\185\151\159V6\216\185PdLt\191\150\245\192\162\212\136\255sCR\243\193L\245\NAK\192\227\EMr\230\211, \SUB\248G\248\222i^]\216v\FS\152\229\146\226\SUB\223$g.\217J\240K9\RS>\SOH\195\162u\235t\234\224\142\141D\179p\155\133<\198\213NJ\214\217\194\216'\ETB\DC4\US\ENQ\159\DC2\RS\245\227\138\196J\GSE\143J\218\148X\ACK\166\n\186\253\255\235{8\190k\129\156_\ESC\GS\199\140=\EOT\214\188o\146\215\168\157\238|!\183\216\135y.\252=\185\n\CAN\192D\196og\188XT\154\194=\145!QM\158\SI=\146\206<\211\160}\176\228\&9\175\EM\157N\139B{\230Rw\239\248\SUB\191g\224A\EOT\236\vO\161h#\176\235\237\&3\138h'\218\145\215\211I\143\154\\I&\NUL\193\194Y\175\185\234c\238\255x\212\203\177\&0z\142\129\133\252\US\NAKh\249P\162'\195@\160\198\210\220\215% ]\225\203\154\135\216<\144-\251\&8\199\221\163\207\182\131\170X\187\CAN\177?\232\248J\242\234\SYNCn\222\145\US\195\181\SOH\144\209'Q\156c\200B\"w\187=\238W\141uk*_\US\STX-\245\217\228u\FS\161mSr>\SUB\255\148\STX\129\212U\235\DC2Gl\238\253\ETBQ\240;\191H/Zi\149J#\252\233\ACK9k=\195W\156\RS\163\151\185\167o\213Z\254\229b \209n\SUBR\132I\186k\152\171\201\212\187`\244a@\255)\f`\246\160\223\188\167$v\143\225\DC3lO^\ACK\164?\228\143\129\STX{\b\171\SI\160\&4\193N\213\136\181\158\182\DC4Lw`\215\237\186\194t\140>/&\237\149\DLE\206\232\142\169\FS\205vU\FSH\ESC\174\243\"2\169;\220\137\178\146\139\220\136@q\a\SOH\198GLK\227\223\CAN\239HV\165E\ENQtn\152\RSA\ACKxh\t>\243F\145\178\&1!*%\193\181d\214\159\&5\199'j\247\t\180'\218\t\198\162\195\248\n1W\209\180Rh\247\200\146\250\253\RS\207\&6\244\"\SUB~2K\133\188\&4\213\na\176V\165\"\214\167`#\196\184\r\171=\197\200\255e\195\130\223\240\207Q\235\212\170H2\190D\170\188S\209\210k\168,\202\232\DEL\US\n\DLE\218\157\190tO\a\239\&0\252\217\251>X\236b\239=\220F3\132w\159&\"\195\201\226w\199}8\154l \166\244,>u\160\DLE\135\235\246C\b\250\197\225z\ENQ\128\b\170\226\187\ETB\b\CAN\156\US\251\SUBz\ETX\tch\178H\202\228j\240\208\&3+\131\163\237T\161\160\&0XP~HE\186\ESC\220:\150y\231\&7\175\180\DELS\158KWV@\SO~Y$\243ok\224\184\154,\250.\\:\234f\185\198\SOH&.\DC3\246\195\155\&3T\ENQ*j\"\164\b\152\166\SOHx\143\193\n\211\192\188\FS\DC3\a>n\a\146\160G`\151\210F\213\228\220\180\EM\233;\229\177\249\n\253\&2b\169Q\164\213\163:\GS\236\203\r\CAN\231VG\237bW\207J\228qD\DC2\253\201\138C\NAK=\208^\bN\163\133\NUL\SYNJ\217\187\162\134\187\181C\200\144\237P[G\161\170{DK\248\182L\162\129~\158\249\227\185\225\244\218Zd\244r\205\171a'\169\231}\196\DLE\230\203V25\245|\163\&5\176d\219\141\244\253\175\166\216\167J\168\144A\227(\213\ACK\SOH\249\164\&6!\184\235\152\168IV\133\156\129%{@\145\168\219\189\188\225\&5\DC2\143\134h\169/\142\166\".e`\209IG0[}\137\147\tj\SUB$\210\170\202\190_\135\252K\176\142%\133z\219#\212\&7\SYN\216MM6{~\a|\144\202\RS\229\190\130\SI+\GS\ETB(\245/Ea\247*\SI\186%/\212\177\149\bz\154\159Fx\167)hv\t,\EOT\176\144\147\131\176\163\200\176\143eV\132\221\163\238\v\153X\217`\236\230\DLE\228~\tjC\ENQg\200\221\219vy@\ETB4K\SO9k\216z\RS\133\SYN\237\147\233\211\185\166\DC4&\213^\135\160\RS\178\250\187|\129\147T\255I$\230\167\134\137\162\167\211\223`\ESC3p\FSl\135J3\201\185\252Y\187S\152t|\148\\Uo\208\248M\235F\171\&4\SUB\NUL7X\ETBC\ETX\FS\155\SI\201\NAKt\nF\220\&5#\175\192>[|5P\f\176\252\253o\b+k,$\149? \SOH\142\203\&5\245F\200\200y\218!\205\151t<\184\238\177\199\179!C\255C\ETX\226\179\138\&7\\\189\SOH\244\n\192\&2\v\156\206,u\DLE9\248\237`\DC1\227a\211f\SOH0R\236\&6B\133Jo*\159\241\&1N\181\169\133@\171\161p\149\187e\159\189\215\245\237 n\f\219\236\SOu\221\234\RS\188\NUL\r\199._\STXRF\ETX\178\205^\139\168\145\RS\193\198!\199\v\199\183o\239\230\248\150\175]T0~J\199\240\254,\132\167v{\220\219\189\217a+_\252\DEL\166\&1 e\SO/\161\132/\ETX\196\171\205\175b=\196\188\SUB/\v\181\221\189\SYN\220\168\133\194V\225\153]T^\177/\209C\210\249\155$\204qe0_\200C\170\131\228\252q+U\239\\\141\135\152\221\230\135\183\223\235bn!$\137\181\139\209\192\&0n\136+\146\131\132\217\243\180:K9\DLEkw\217\217\252S\STX\171\209\185%\145W \238\233\137\199\&7Q\139\158,\ETXh\176\187\190\&1sr\162t\221\193\131\244s\CAN\187=S\232l\DC2\138\157\184\203\189:9\165\SOH\250k$\189\SI\247a\SOH.\141\199\252\aEW\210\176\176\225\239\172\152\198\NAK\254\SI\249\172sb(\189\DC2\DLE7\233\221o\STX\181\210\SI\186\148KB\229\219\216\185\208\181\SI\234\194\208h\148\155\160\&1\183x\DLEo\EMF\241J\234\255\217\203\157,\ESC5z.\195\nL$o(4\170\174\235T+p\222\236\247\182\248R\143m\198H\208\245\ENQ.\156\232\241QUx\248\234\168g\168\190\180\226\203\ENQKu\152`[\163}\182\182\158Ue\ETB#\228\DLE:\206\NAK\237\185\159\r\208(\221\176\DC1h\242\158\160&!\166\137J\186\242t\235\190\aV\145C\235C\160}\249\133S}z\155\DC3\NAK)\144?}\227\170\169\STX\255\n4\165P\ETX`\161&\v\181\200\CAN\t\178\145U\STX\250M\144\147\134>\151\149\145y6\150\193\192\fk\137\219\129\137\255Fe\SUB\155\219\178\170\GS\201\STX\203\a\197>b\230:\128\STX\161t\135\134~\177\&1\240\149\194Pmn\222\142\170\189\EM3\221\ETB\182\146\166\161\180_\144S0M}\154\172\197\181\171\160eS\DEL\244\156\211\207ji\244(\153\150\150\252v\146cd[\237:&V\141\175\CANd\209\134v\240\163*B"
edB4096 = "\246\144\EOT\STX\137\189\244\&0\239l\203{N'\222\152\247\SUB\130\187\220\195\186\204I#\151\142\224IK\230r\201\164<\FS\237\\\147\ETB\SUB#\247\180\218k\SI\fkHb\168\ACK \214\180\214'\201\177\142(\t\211\183\n\153,\183\165\r\175J\222\208\187B\239#$\US\n\173\167\&2X\223\254\238\172\212\222\144\242Z-\215\RS\140\183\228\130\186\211-\NUL\226\217\CAN'\FS!\vfr\149\166\250s\ENQ\DLE\251\SOH\201\210>\f\220\189B\236\227\133dM7G\170d\192\186\&4nY] m\236\174\181\184*\150\198\243 W\230D\SUB-*\174\221\157o\255\DC4X\242\254@\DC3\165\207#\160\148\&0u\SOHl\n\172\133x\144\254;\DEL\168\166\240\189\RS\141!B\ESC\224MBq\156\ETBRY\GS\201\235T\EM/ \166\202\128\233m\237\222Sk\159\f\198\239\252}\r\b\240f\224\211\148\155[\133_\163\230\255\204\221\167\172\SYNl\131\255\219B#\146e+\174\175!\171Qc]\242\&9\252\138$hD\"\210\bf\176\218,\ENQ\171\DC2\160\149\205\SI\SUB\ACK\171,\DLE\FS`8\DLE\194\139\166O\175\250\NULtO\f\SYN5\254U\ETB4\200N5\220\252\172\208\ENQ\227\&1A\US\SO\240\FSI\201\&8l\131z\212\161)\144\GS;QP\199\130\157\135\214$T\141\245\r\172\244}L\180\181F\148\250\247\218\172\246OcW\169~\NAK\205\174\232qA\DLE\187Sz\174\244\232\NAK\231\254\224m,\210\157\DEL\202$\218P\240\&785tnR9\249\134\231\&1\nJ\209Km\148\175\194\234W\ACK\195\143\206\194_\163KK\176\SYNs\229\EM\169,\RS\188{\253}\153*\DLE\213&c$\197\247\t\131T%\169\228\218-\238\187\166\171\155\SI\t\131\178h\NUL\145\144uf}d\196\130\182\DLE\191c\162\STX,\EMk\236\205\n\NUL\196?[\218X\146~\n`\151\140\234\136\ESC+\ESC\236KVW\ESC\150\a\SI\130P\EM]\241\160\197\203}l$\ETX\196\146k\242?5\147\210\224a!\v+\243\DC2\206H\251\154\188\164>\135\228\SYNO\194\130\130\160\139g)\183\ACK\214\134\255\148\198m\168\176\b:\206\216\220\255\"\169\128D\183\143J\226r\183q\129\173\204\SO%\NAK\205\EOT\252G\182\246d\145\229\153s\173\n\223[\205w; 3dZ\162\253\169\r\FS\b\ETB\246\135\209\190\223\199\241WQ\234Dz\150\255\NUL\134Z|9\173v0O\f\DC4%c\196y\153\200\254\193\147v:[\SUB\205\211]X6\224\160\163\214\181\214\"}\220u+\208\b\163\&6\r\179\229|\ETB\173\158\ETX\223\176y'\DC1\217\229wv\ESC\174\176\201ub\DC4\133+#\SUB!\213\221\DC3\SUB\155\254A\212\134pq\134\194\167I}\133\ACK\156\216\247vj\"\145\188\248~\a\178m\141K@\183\201\234\ETX\213\195P\145=\170\133\180r\138#;!\SO\RS\\\222\131\207\255!eY\185G$\EM\166;\SYNl\182\191\SI\223!}\n\238\167\178\227^\186\&3\255\135ia \133n\188\238\131\FS\138\148kC\228t9\229\153<b\169\216\255.R\241\GS\212\248\STX\172\212+,-U}\227:h\225\181\v\242\129\227\213LJyH\EOT\218\243~\SO\174\EOT\SUB_\175I\159\202\255[\144\214\146\ETX\a\220jO=\192R\201\242\170Zn|\207\RSm\205\151\241|\228\213\202\\;\USfh\209\160\240\DC2\145\179\201.\DEL\174m\195\159}\154\168\255\201\159\255\146T\SO\SO\v\ETB\v\ENQ\151\&6\231\237/E\200k$2}K\200j\228[\170\f\135^{\190\&8+\200<2\156R.\201\229v\SUB\247\142\EM\137\229\184B|\211\&6E+^\\\148W\131\192\153\180oaCo\227\239\212\179\NUL\210\176\RS\212\138\219XF\237\175\228]\158\250\247p\156f\217\210\DEL\DC3\168\149Kbz]\202\220\"\196\186\206X\219\SOHP\218A.5kK\NAK\177\192\172\173}\206VU0\149\134p_J\162S\171L<CDMdm\145\221\SUB\200\190\218U\175 6t\159R]_\164LT\213Y\196\149\151\172\&1\r_\205\208h\144\&4\142\234s\252\rIf^\NUL9\200\216\SOHF\214\220\185\154\EOT\143~\251X\DC3S\130\128c\243\168\224\&6\168;b\DC37\184X\vd\"\174\157w%\133\163`)\SOH\199\177\225?\240ia\134V\182\159\243\200\161P\249\CAN9\237\194\185\ETBt\206\177Z\147\199i%\197\134\SOH\212\185l\139y\239\"\CAN\147%\139al\rr\254k\251\233\154Z#\ETX\SO\175\139\130\\I\247\175\176\144\152\144\&6\NAK*\216\EOT\131\244\154\215QuK\241\250L\216\228\154_\DEL\207\210\140C\178\216D`\130\167\EOT\\n\238\218\252]\147\&8\172\&2\STX\FSC\196\r\222y\USN\227T\EOTy^]\178\ETXa*\209\147+Xn\164lZBeE\138\250\201f6\200\&8\219\164\n%4\162X\NUL\243O\221\SIv\176+\135\135{\143\146\253\141)\159\231]\236\152\ETX\138\209\US\214\FS\DC4\172\SI\174\224Z\163U\181h\185;w\RS\238\231{\136\149\142|\136\220\207\219R~Qn\208\238\183\v\143|v\149\179H\244\176\162\DC4\193\188R((\174\223(W\217\207\134\226\225\164U\ESC\246\252\CAN\148\255\147SK\189:X\133\163\217\DC4\174\245F)u+\220gB\179\242\211\233\DC2W\180\229\SUB-b\197\ETXzg\219\183\199\201\163\130m\133\209\177\ao\133\217\245n\NAKk\190\&3lG\225&$\134\243\143\206\167\254&\DC1\NUL]\140\148\DC2\165\154\164\"\210\228@\144\154O\160@l\167\152*u\248\137U\176\179G\144\199\172e\168\128\199l\191\172\244\164@Y\214\150\144e\172O\RSQ\207\142\170\154(\b\ETB\180\137\248P\STX\135(r\247!\220d\ETBel\f\142X\178CG\160\186\204xx\253\255<\NUL\129\v\177f\163T\NAK\184\161C\160\175\173|\174\SUB\144\212\223\173n\216\r\187\GS\241i\172\&9\CAN4\DC2>h\224\211\170\161,#\239\217!=\144\133\191\187u\f\241\217g\218\EOT`0\150\206\SOH\196\228\167\207\238K\229\249G\SYN\SO\241\219rm\207\&2\187RMX \215\210Q|`\145\154\185\233M\220\&6\ETXS\252ZT.-\CAN\145fo\134`\214\DC3\214\DC2\210i\198*\144\DC1\155\206\FS\189l\183>\139\&2\130\&9\186\141\a)\171r\164\243\151q\218~Y\ETX0S1\STX\DC3\253b\212\v\195\141\&6\169\131\203#\136\162g%\129\f\151\236\183\170l|#\186sW\225\194\221\ETX@ \212\138\159\191;\EM]\200\STX\187=\255_8\205b\204a\138\173\231\187\144\SI\168:\191e+*\134\213\201\197\205\131\183\140\209\230\&5i'\133j\RS\226\ETB\197\US\161H\fJuX\191\207\a\142\145V\ESC@\212C\205\RS\244\155w\ACK&!\177S\196\191>\190\RS3r\247\244/<\CAN&\224\143\187\158\220\134\235\160\245\&5}\204\213w\161\173\187\172\132H\192\222w|\190\248\212\146(Zd\175O\145A\229|\171\NULM\132\215\226)\189?L\ETX\161-\237\SYNq8\186W\n.H\222\159.+!\178\186\DLEbk^\246\202\246\207\247\218\DC14\175\136\202x\217C\195\213\167\252b\SUB2$\DEL`\147X\184\228\212\&6-\172\NAK\216m5\138\EOT\182T\FS\153\248c\165\206z\168\241\183f{J\207V#\167Y\153\134\213\253A\STXsv\SI\217Y\239\DC3\189'\184f\220\255\205A\154\248$G\233\231\210y\216\253(\183I\206\173\RS\223\227\173\231\203\237\186\146\205|\209:8\248\184\DC2\246[u\229L/D\219\GSM-2\168\228\163\230\DLEa\SO6\163h\203\215\211]\210\&41\DC3\161\153\221\135\248roOr\219\231c\DC3~K\200\&8,F\129\188$\161\"\130\187G\132jw\204\DEL\198(\\\234\182\219\235\137\241\180\n\246\165\133X\178\254\DC2\219\SUBu\SOH\164\151\173\225\DC2\164|%\222\235\129\235\193/a5lAV\176\196\175\aO\140\132\145\162\216M)\146\254\171\232\&3\ESC\132\231P1i\241\209;\GS\SYN)k$\173\177\208\187ZdO\t\198I1I\167lEc\SOH\n^b\204\222\145\156\171\&5Q\255\208\172\163\149\r\230pN\GS.3\155\142\244\169\218\166o\206C\183H\241[\255\128\236\233\201u\234\n\200\140Z\229\208 \198\206\254q\223\178\167H\159\STX\235\191b?;[4t\171\242\DC3\233\199\154\179\208V\206\243%\226\153\207\179\205\217:`i\186g\160\240\SI\170\141^[Kv\RSw\189\253\174]\167\231BF@i-q\141\205?.WW1\US4\EOT\179\240\150o\131\129\f\155#\242<\204v\202P\151\208=\NUL\253{\b:\152\196x\182YwM\191\243\146\244z0^GNW\133D\181\242\153\227\236\DELt\ETB\242vs\187\145\134o\182\166T\150P\253\246\237\142\203>\a\165\136U\169\&4(dyS\173j\191=\159\243\179\DEL\US\189R\133\134\205\170R\232\SOCB\224\"\SOH\167P\NAK\145\235\173q&T\233\166\145\220\221k\207\206\247\186V5{\ETX\252B!\140\ETB\DLE\DEL\143\139~h4\140\171\ETX\141\248\182\189-\198\185\202{\220\249\214\165D0b\226dy\153gb\CANd\214\246\a(\SOH3\DC3\v\DC3P\175\165\231\149\DC3;\US\194*a\174\216 \129\145\216ta\215\166\200jT\147\SOH\151G\SO\176\171\213\192\216\bU@\149\178\205r\134\EOT\FSw\234a \224\rgq\168\155H\196>w\EM\NUL\190\ESC\131gc\203\168\185\195\254\v>\250.\209\234Ha\230f\152iQPx\172)\SIaXh\209\ETBQi\242W\STXD\147x2\219D\137\&6fn\244\ENQ\184U\221D+\GSH\185\218/\170R\166\231{\198{\195\216#\a\RS\243\240\236O\199\164\207\158\178{N\189Y;\238s\190\232\129L\199?\225X\155\&3M^\SO2\174\&62;\217ks\131\158\r{+=G2\"\157z\162\140\ETB\253\DELt\233\243\190D<\202\f\247\178\147\236\158\128L\195\180A\170_\167\191 XS\198\241\176Uz\DELW\176\SI\249\b\148\SIj\183\171 azv\177\143\208\242\225\201\205\227\220\236s\SO\224\191\229,\174Q_\ETB\172\133\STX\158\ACK+m\177\185v&\173\a\159\191o\189?\250\189Z\206\154\&9~-33\NUL\137\178\147OF\217\SO\221\249R$^\163\167L\167;C\ETX\184{\247\SI\STX&k&\196C E>=\DC4f\a\182\239\SOH/\135\165@\184\252\a&M\188=;\177\&2\213@\172h\ENQ\155\228\&8A\203\220\SO\221\216\196U\EOTS\253\228'\153\142\198\183$\159\146\196\176j\241u\176\&9\a*\202ZVV\ESCMw\173\172\151\193\170\137<?\206\151\DC1*m\CAN7\178\219\251{V\207\171\DELP\249\136\"\229p\ETXE\DC2\177\\\NAKol\146\163a\198L'\160,\177\214\254\200\DLEv/@\138\140+\n\232\250+-\187\240\167\ENQxP\199#\140\154Z\f\193)\188\SOH\129\238\179\152_\254bF\"r\158u\232\130f\249^\229B\217v\129P7\138\208\140\230P\166\n\232\238\178\241\155\255\183\226\174%\164\165\149L\RS\211\152_)\210F\141\188\236B\211\&2c\233\133xeFI\146y\216H\CAN\136\137~\159\161\132\251#\147hT^\239\164kA\128\FS\148\177\202\CANU\131\179dL\224/\146\223=\154\254\149a\197u\131\252\STX\169\210)H\251e\129\v\231>\204<'\128A\ENQ\219I\252\175M\129pj\140\SI\250!\179i0\178m<\220a\187\201\EOT\210\ETX\211\219\214\151\184\&7\168_\238\217\195\228\ay\245\219\193E\250\STXMsV%\174\193[\144\EM\216~\193\136\231\217\&5\133\255j\229\188\173\b?\NAK\244Y5\230\239\191\248\RSG\238\192w\194\234\217\249q\241`4=\167\128\\\172\231\"\163\232\234\211\190\170\219U\138O\159\156\177e\132Q\150\ETX;\US\SYN\DC1L\238Cn\195\&2\204\GSR\n\183\235\DLEY%\168\201Of\175\181\&0y\137\244\190\GS\179Q\167\EOT\219\132\EOT\176\215\245QT\146\168}\183)\233\241\200\&0\151\211H\tC!(\206\177\183\130\152[=KJ\141\ACK\b\209\NAK'\155|J\220|(\178\&4\DC4\SYN\183\233D\225Yt\NAK\243T\143\CAN$\190\255\NAK\213\253\128\171c\EM\204\ACK\153e\131\163o\STX}0\165\248\205\&2\222U%\181h\229\SUB\165y\186B%l\DC2\ACK\218\147h@\201T:?\212y\155\169\238\207\176\138'\208/\167\253uQ\187\t\240\184\135\195<\162\245&\142)JW\254\164\240\&6F\147\142v\235\194\169\224\CAN\183z\168\254\SUB\137\144\&9\155\234P\186U{t*\138\153\&1\\c\201s\157i*\130\ETX\175\234\223\&6\177\&5Q\v\235\236\182T\193V\253\196\241&\228\230'\177\&7C\196L\228\179\177\249\n\DC1\174-\184\194<\153\236 \RS,\253\158\212Z7`8\131\196\173\EM\150\199\216\193g\197\EM4U\135\191j\207\&3\SYN\227\230\198\140>^I\EM\241\182}\181h\193\&04\148\te\DEL\206\233\&0{\DLE\SYNh=\143\NUL\fp.\169`\226\228\222T\FS\252Wn\180\&0>C\201\244\190\201:\214^\249,\158w\CANc\198GD\195aP\DC1V\208\209Jf\190d\255\234\246Kf~@T\181\CAN\154Gp\232D\151\228\ETB\\.n\133\248\232\164-\185\&1^q\171\179\&7\236\STX?\197\181E\212\193E\175f\134JJm\222\168\172\138\US\254\208\255\132\198\144\254AO\164\ESCM\137\130\&8\162\249\215\186\139Vb\156q\143\ETB_8Z\183[\187\&0E\198u\200\227h\176\131V\179\166fA\b\STX\239\GS\223h\196\241\181A;\ACKS\235\251}\203Ns\239\224M~c\215\DC4\ACKf\207>\172\ACKv\210\NAK\234QR\169\168\t\DLE\183\194\222E0\148\248\214\181G\203\242.\196>\140\199d\171P(\DC4\199\208(\225\205\232}u\247\166\&2\206\160j\185\212\145F\226\182\251Z\233<\129L\203\138\r\232\244\b\132o;\170\215\144\146\162\135\154>j\186\220\167\255\DC4Zr\191\187\145p/\183Q\202\230\243_'\245\214\DLE\171\162\131\v\194D&\171Y\152\224\133\RS\128\212\SI\141\251\236\217\174S\STX\164\202\163#\157#\183<I\b!&\191\173n\DC17qCl\193H\193\220\&4#\179\209\181\161;wy*\179\SUB\164\142\FS\DLE\STX;\150\193\227\211\150\172g\175j\175\SOHp\246\&5\176\234\241\228\182X\197-\203U\213\161\STX\US\148\200K\159\&1\EM3\136\251\&1\182\156\&1\\\156k\131?\STX\239c\152\128\144\164$\142\143\SUB\203\169\137}N\173\200\v\240\247\171Fu\203\156\t?3\149\201\161\150,\183\173q\226\223\f\181\206\142q\139\138|\213z\216y\ETX\161\&5\206\193\238N\161\175\236g\253Y\230\&8&w\237\SIX\251\179N8Pa\SUB\174r\SO\ENQ\132\DC2\138\225R\204G\161pQd\197\SO\208\219\236\216\DC2\149\RS\148\151(83\ESC)t\198u\192\227\SO\170H\142\233\211\NAK\DC4\247\161\222\185\227\161\178\212D\209<0\201\RS*\153r\179\v\141\252\226X\209R\FS\199\144\210\210\220\ENQ\153\&1'QK\163\136\179\234\231?&\128Ak\EM@\246U\135^\192\175\129t\160\225\&3\183)\213@\200\233G!\128X3\134?%y\186\207\209\182\204\194\t\209\232\243\DC3ja\251h\132!\203\220\228Dv\DC4\r#\STX\222t\205\241\229\&2\ENQ\195\151T\162<\186N\249l\227\203\DC3?\230\176\173W\146\161\r\187a\220p\GS\176;9\238}%s\146T\184:\GS\184\SYN\200\&6\217\221\177Z\169\DC2\171\NUL\242\153\DC2"

edSigB256, edSigB512, edSigB1024, edSigB2048, edSigB4096 :: Ed.Signature
edSigB256 = Ed.Signature "Z\194\228Y\151a\218t\254\187\158@2\198\&9\SYN\v\147\255,\227\bV\239\150D\SI\146\218\153\151\201{?\DC1 \222\SO\208L\n\223I@HKw')cc\214\195\233\DC4\165\a+\138'I\196A\r"
edSigB512 = Ed.Signature "0\246\242\130/\162V\150\210,\212\240\&9v\f\143{\213\241{\245\215\&2\167C\231,\GS\DC2\175jP\210\161\243\216Q\RS\151\206\255>h\134\158l\161\211E\166a\241V\US7\130\219f\243\186\aWx\f"
edSigB1024 = Ed.Signature "\210\152\228FzRUi&\156\138\209\165\224\206W-\DEL\176\176\&2\132'$\236/\CANm\226\152\227\173t\248\ACK\245\242i\182\200\196Ju\137\&0^\180\208\SOH\245\192>\200\ENQ#\142X\SOH\191\139^\246\223\r"
edSigB2048 = Ed.Signature "}\144yrk$m\254G\160\215\211k\203\168\191\156\DLE\180\169e\147\159\199[\191\201\196&u\b\ETBA\250d\217\&4Y9\ACK{+\215\224\&3\138\DELE\226\212\219dyF\133\211&W\214\DC2\150\155\235\ACK"
edSigB4096 = Ed.Signature "\200\164\166\206p\252Z\175M<\DC4\ETX+\217A\242\158 \246`\202\182)\207 \255\191\148Vyf\158\CANOsN\210\a%\174\176\233\t4g\EOTPxF\158D5M\186\158\186\133\CAN9\224{\173~\STX"
