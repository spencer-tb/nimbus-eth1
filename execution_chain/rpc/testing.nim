# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/typetraits,
  json_rpc/rpcserver,
  ../../execution_api/[conversions, execution_types],
  ../beacon/[beacon_engine, web3_eth_conv],
  ../common/common,
  ../core/[eip4844, eip7594, pooled_txs],
  ../core/tx_pool/tx_item,
  ../transaction

proc validateBlobWrapper(
    ptx: PooledTransaction, com: CommonRef, timestamp: EthTime
): Result[void, string] =
  if ptx.blobsBundle.isNil:
    return err("blob transaction must be in its network form with blobs, " &
      "commitments and proofs")
  if com.isOsakaOrLater(timestamp):
    if ptx.blobsBundle.wrapperVersion != WrapperVersionEIP7594:
      return err("blob transaction wrapper version 1 expected from Osaka")
    validateBlobTransactionWrapper7594(ptx)
  else:
    if ptx.blobsBundle.wrapperVersion != WrapperVersionEIP4844:
      return err("blob transaction wrapper version 0 expected before Osaka")
    validateBlobTransactionWrapper4844(ptx)

proc setupTestingRpc*(ben: BeaconEngineRef, server: RpcServer, blobsOptional = false) =
  ## With `blobsOptional`, a blob transaction may also come as an execution
  ## payload carries it, without its blobs, commitments and proofs: the block
  ## needs only its versioned hashes, and the blobs bundle leaves it out. Only
  ## the client test runner turns it on.
  server.rpc(EthJson):
    proc testing_buildBlockV1(
        parentHash: Hash32,
        attrs: PayloadAttributes,
        transactions: Opt[seq[Web3Tx]],
        extraData: Opt[Web3ExtraData]): JsonString {.raises: [RlpError, ValueError].} =
      ## Builds a payload on `parentHash` from exactly `transactions`, or from
      ## the pool when null, without touching the canonical chain.
      let
        com = ben.com
        txs =
          if transactions.isSome:
            var items: seq[TxItemRef]
            for raw in transactions.get:
              let
                ptx = decodePooledTx(distinctBase(raw))
                sender = ptx.tx.recoverSenderCached().valueOr:
                  raise newException(ValueError, "invalid transaction signature")
                (size, id) = getEncodedLengthAndHash(ptx.tx)
              if ptx.tx.txType == TxEip4844 and not (blobsOptional and ptx.blobsBundle.isNil):
                ptx.validateBlobWrapper(com, ethTime attrs.timestamp).isOkOr:
                  raise newException(ValueError, error)
              items.add TxItemRef.new(ptx, id, sender, size.uint64)
            Opt.some(items)
          else:
            Opt.none(seq[TxItemRef])
        extra =
          if extraData.isSome:
            Opt.some(distinctBase(extraData.get))
          else:
            Opt.none(seq[byte])
        bundle = ben.generateTestingBundle(parentHash, attrs, txs, extra).valueOr:
          raise newException(ValueError, error)
        timestamp = ethTime bundle.payload.timestamp

      if com.isAmsterdamOrLater(timestamp):
        EthJson.encode(GetPayloadV6Response(
          executionPayload: bundle.payload.V4,
          blockValue: bundle.blockValue,
          blobsBundle: bundle.blobsBundle.V2,
          executionRequests: bundle.executionRequests.get,
        )).JsonString
      elif com.isOsakaOrLater(timestamp):
        EthJson.encode(GetPayloadV5Response(
          executionPayload: bundle.payload.V3,
          blockValue: bundle.blockValue,
          blobsBundle: bundle.blobsBundle.V2,
          executionRequests: bundle.executionRequests.get,
        )).JsonString
      elif com.isPragueOrLater(timestamp):
        EthJson.encode(GetPayloadV4Response(
          executionPayload: bundle.payload.V3,
          blockValue: bundle.blockValue,
          blobsBundle: bundle.blobsBundle.V1,
          executionRequests: bundle.executionRequests.get,
        )).JsonString
      else:
        # Before Shanghai a block has no withdrawals, and before Cancun no blobs
        # bundle, but the ExecutionPayloadV3 response lists both.
        var payload = bundle.payload
        if payload.withdrawals.isNone:
          payload.withdrawals = Opt.some(newSeq[WithdrawalV1]())
        EthJson.encode(GetPayloadV3Response(
          executionPayload: payload.V3,
          blockValue: bundle.blockValue,
          blobsBundle:
            if bundle.blobsBundle.isNil: BlobsBundleV1()
            else: bundle.blobsBundle.V1,
        )).JsonString
