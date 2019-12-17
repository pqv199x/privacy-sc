pragma solidity 0.5.0;
pragma experimental ABIEncoderV2;
import {Secp256k1} from "./Secp256k1.sol";
import {UnitUtils} from "./UnitUtils.sol";
import "./SafeMath.sol";
import "./RingCTVerifier.sol";
import "./BulletProofVerifier.sol";
import "./CopyUtils.sol";
import "./TRC21.sol";
import "./Bytes.sol";


interface IRegistryInterface {
    function getPrivacyAddress(address _normal) external view returns (bytes memory);
    function getNormalAddress(bytes calldata _privacy) external view returns (address);
}
contract PrivacyCTV2 is PrivacyTRC21TOMO, RingCTVerifier, BulletProofVerifier {
    using SafeMath for uint256;
    using UnitUtils for uint256;

    uint256 constant DEPOSIT_FEE = 10**6;//deposit fee = 0.001 TOMO = 10^6 GWEI
    uint256 constant FEE = 10**7;//send & withdraw fee = 0.01 TOMO = 10^7 GWEI

    struct CompressPubKey {
        uint8 yBit;
        uint256 x;
    }
    address RegistryContract = 0xbb32d285e4cF30d439F8106bbA926941730fbf1E;

    struct RawUTXO {
        uint256[3] XBits;
        uint8[3] YBits;
        uint256[2] encodeds;
    }

    struct NewUTXOEventStruct {
        uint256[3] Xs;   //commitmentX, pubkeyX, txPubX
        uint8[3] YBits;        //commitmentYBit, pubkeyYBit, _txPubYBit
        uint256[2] amount;
        uint256 index;
        uint256 txIndex;
    }

    struct UTXO {
        CompressPubKey[3] keys; //commitmentX, pubkeyX, txPubX
        uint256 amount; //encoded amount
        uint256 mask;   //encoded mask
        uint256 txID;
    }

    struct Transaction {
        uint[] utxoIndexes;   //indexes of utxos created by the transaction
        byte[137] data;
    }

    UTXO[] public utxos;
    Transaction[] txs;

    mapping(uint256 => bool) keyImagesMapping;


    //--------------------------EVENTS---------------------------------
    event NewUTXO(uint256[3] _Xs,   //commitmentX, pubkeyX, txPubX
        uint8[3] _YBits,        //commitmentYBit, pubkeyYBit, _txPubYBit
        uint256[2] _amount,
        uint256 _index,
        uint256 _txIndex);
    event TransactionFee(address _issuer, uint256 _amount);
    event NewTransaction(uint256 _txIndex, NewUTXOEventStruct[] _utxos, byte[137] _data);

    /**the first step for every one to use private transactions is deposit to the contract
    *@param {_pubkeyX} One time generated public key of the recipient for the deposit
    *@param {_pubkeyY} One time generated public key of the recipient for the deposit
    *@param {_txPubKeyX} One time generated transaction public key of the recipient for the deposit
    *@param {_txPubKeyY} One time generated transaction public key of the recipient for the deposit
    *@param {_mask} One time generated transaction public key of the recipient for the deposit
    *@param {_amount} One time generated transaction public key of the recipient for the deposit
    *@param {_encodedMask} One time generated transaction public key of the recipient for the deposit
    */
    function deposit(uint _pubkeyX,
        uint _pubkeyY,
        uint _txPubKeyX,
        uint _txPubKeyY,
        uint256 _mask,
        uint256 _amount,
        uint256 _encodedMask,
        byte[137] memory _data) public payable {
        require(msg.value.Wei2Gwei() > DEPOSIT_FEE, "deposit amount must be strictly greater than deposit fee");
        require(Secp256k1.onCurveXY(_pubkeyX, _pubkeyY));
        require(Secp256k1.onCurveXY(_txPubKeyX, _txPubKeyY));

        (uint8 _ybitComitment, uint xCommitment) = Secp256k1.pedersenCommitment(_mask, msg.value.Wei2Gwei().sub(DEPOSIT_FEE));
        (uint8 pybit, uint px) = Secp256k1.compressXY(_pubkeyX, _pubkeyY);
        (uint8 txybit, uint txx) = Secp256k1.compressXY(_txPubKeyX, _txPubKeyY);

        utxos.length = utxos.length + 1;
        utxos[utxos.length - 1].keys[0] = CompressPubKey(_ybitComitment + 2, xCommitment);
        utxos[utxos.length - 1].keys[1] = CompressPubKey(pybit + 2, px);
        utxos[utxos.length - 1].keys[2] = CompressPubKey(txybit + 2, txx);
        utxos[utxos.length - 1].amount = _amount;
        utxos[utxos.length - 1].mask = _encodedMask;
        utxos[utxos.length - 1].txID = txs.length;

        UTXO storage lastUTXO = utxos[utxos.length.sub(1)];
        emit NewUTXO([lastUTXO.keys[0].x, lastUTXO.keys[1].x, lastUTXO.keys[2].x],
                    [lastUTXO.keys[0].yBit, lastUTXO.keys[1].yBit, lastUTXO.keys[2].yBit],
                    [lastUTXO.amount, lastUTXO.mask],
                    utxos.length.sub(1),
                    txs.length);

        addNewTransaction(_data, 1);

        transferFee(DEPOSIT_FEE);
    }

    /**Send TOMO/Token privately
    *@param {_inputIDs} The index IDs of all decoys in all input rings, data is structured as [ring00,ring01,ring02,ring11...]
    *@param {_outputs} commitments, stealth addresses and transaction pubkeys of outputs produced by this private send
    *@param {_amounts} enrypted/encoded format of transaction outputs amounts and masks/blinding factors
    *@param {_ringSignature} ring signature that will be verified by precompiled contract
    */
    function privateSend(uint256[] memory _inputIDs,
        uint256[] memory _outputs, //1/3 for commitments, 1/3 for stealths,, 1/3 for txpubs
        uint256[] memory _amounts, //1/2 for encryptd amounts, 1/2 for masks
        bytes memory _ringSignature,
        bytes memory _bp,
        byte[137] memory _data) public {

        require(_inputIDs.length < 100, "too many inputs");
        require(_inputIDs.length > 0, "no inputs");
        require(_outputs.length % 6 == 0 && _outputs.length <= 2*6);
        require(_amounts.length.div(2) == _outputs.length.div(6));

        //verify signature size
        require(_ringSignature.length > 16);
        //[0]: numRing
        //[1]: ringSize
        //[2]: key images offset
        //[3]: key images offset
        uint256[4] memory ringParams;
        uint256[3] memory loopVars;
        ringParams[0] = CopyUtils.ConvertBytesToUint(_ringSignature, 0, 8);    //numRing
        ringParams[1] = CopyUtils.ConvertBytesToUint(_ringSignature, 8, 8);    //ringSize
        require(_inputIDs.length % (ringParams[1]) == 0);
        require(ComputeSignatureSize(ringParams[0], ringParams[1]) == _ringSignature.length + ringParams[0]*ringParams[1]*33);

        ringParams[2] = 80 + ringParams[0] * ringParams[1] *32;
        //ringParams[3] = 80 + ringParams[0] * ringParams[1] *32;
        ringParams[3] = ringParams[2];//ringParams[2] + ringParams[0] * ringParams[1] * 33;

        bytes memory fullRingCT = new bytes(ComputeSignatureSize(ringParams[0], ringParams[1]));
        uint256 fullRingCTOffSet = 0;
        //testing: copy entire _ring to fullRingCT
        Bytes.copySubstr(fullRingCT, 0, _ringSignature, 0, ringParams[2]);

        fullRingCTOffSet += ringParams[2];

        //verify public keys is correct, the number of pubkey inputs = ringParams[0] * ringParams[1]
        //pubkeys start from offset: 80 + ringParams[0] * ringParams[1] *32
        //this does not verify additional ring (the last ring)
        fullRingCTOffSet = copyRingKeys(fullRingCT, fullRingCTOffSet, _inputIDs, ringParams[0], ringParams[1]);

        //verify additional ring
        //compute sum of outputs
        uint256[2] memory outSum;
        //adding fee to sum of output commitments
        (outSum[0], outSum[1]) = Secp256k1.mulWithHToPoint(FEE);
        for (uint256 i = 0; i < _outputs.length.div(6); i++) {
            (outSum[0], outSum[1]) = Secp256k1.add(outSum[0], outSum[1], _outputs[i*2], _outputs[i*2+1]);
        }

        fullRingCTOffSet = computeAdditionalRingKeys(_inputIDs, fullRingCT, ringParams, fullRingCTOffSet, outSum);

        Bytes.copySubstr(fullRingCT, fullRingCTOffSet, _ringSignature, ringParams[3], ringParams[0]*33);

        //verify key image spend
        verifyKeyImageSpent(ringParams[0], _ringSignature, ringParams[3]);

        //verify ringSignature
        require(VerifyRingCT(fullRingCT), "signature failed");
        transferFee(FEE);

        //create output UTXOs
        uint256 outputLength = _outputs.length.div(6);
        for (uint256 i = 0; i < outputLength; i++) {
            uint256[3] memory X;
            uint8[3] memory yBit;
            (yBit[0], X[0]) = Secp256k1.compressXY(_outputs[i*2], _outputs[i*2 + 1]);
            //overwrite commitment in range proof
            Bytes.copyTo(yBit[0] + 2, X[0], _bp, 4 + i*33);

            (yBit[1], X[1]) = Secp256k1.compressXY(_outputs[outputLength*2 + i*2], _outputs[outputLength*2 + i*2 + 1]);

            (yBit[2], X[2]) = Secp256k1.compressXY(_outputs[outputLength*4 + i*2], _outputs[outputLength*4 + i*2 + 1]);

            utxos.length = utxos.length + 1;
            utxos[utxos.length - 1].keys[0] = CompressPubKey(yBit[0] + 2, X[0]);
            utxos[utxos.length - 1].keys[1] = CompressPubKey(yBit[1] + 2, X[1]);
            utxos[utxos.length - 1].keys[2] = CompressPubKey(yBit[2] + 2, X[2]);
            utxos[utxos.length - 1].amount = _amounts[i];
            utxos[utxos.length - 1].mask = _amounts[outputLength + i];
            utxos[utxos.length - 1].txID = txs.length;

            emit NewUTXO([utxos[utxos.length - 1].keys[0].x, utxos[utxos.length - 1].keys[1].x, utxos[utxos.length - 1].keys[2].x],
                [utxos[utxos.length - 1].keys[0].yBit, utxos[utxos.length - 1].keys[1].yBit, utxos[utxos.length - 1].keys[2].yBit],
                [utxos[utxos.length - 1].amount, utxos[utxos.length - 1].mask],
                utxos.length - 1,
                txs.length);
        }
        //verify bulletproof
        require(VerifyRangeProof(_bp), "bulletproof verification failed");

        addNewTransaction(_data, outputLength);
    }

    function copyRingKeys(bytes memory _dest, uint256 _inOffset, uint256[] memory _inputIDs, uint256 _numRing, uint256 _ringSize) internal returns (uint256) {
        uint256 offset = _inOffset;
        for(uint256 loopVars0 = 0; loopVars0 < _numRing - 1; loopVars0++) {
            for(uint256 loopVars1 = 0; loopVars1 < _ringSize; loopVars1++) {
                //copy x and ybit serialized to fullRingCT
                Bytes.copyTo(
                        utxos[_inputIDs[loopVars0*(_ringSize) + loopVars1]].keys[1].yBit,
                        utxos[_inputIDs[loopVars0*(_ringSize) + loopVars1]].keys[1].x,
                        _dest, offset
                    );
                offset += 33;
            }
        }
        return offset;
    }
    function verifyKeyImageSpent(uint256 _numRing, bytes memory _ringSignature, uint256 _from) internal {
        for(uint256 loopVars = 0; loopVars < _numRing; loopVars++) {
            (bool success, byte[33] memory ki) = CopyUtils.Copy33Bytes(_ringSignature, _from + loopVars*33);
            require(success);
            uint256 kiHash = CopyUtils.BytesToUint(keccak256(abi.encodePacked(ki)));
            require(!keyImagesMapping[kiHash], "key image is spent!");
            keyImagesMapping[kiHash] = true;
        }
    }

    function computeAdditionalRingKeys(uint256[] memory _inputIDs, bytes memory fullRingCT, uint256[4] memory ringParams, uint256 _inOffset, uint256[2] memory outSum) internal returns (uint256){
        uint256 fullRingCTOffSet = _inOffset;
        uint256[2] memory loopVars;
        for(loopVars[1] = 0; loopVars[1] < ringParams[1]; loopVars[1]++) {
            uint256[8] memory point = [uint256(0),uint256(0),uint256(0),uint256(0),uint256(0),uint256(0),uint256(0),uint256(0)];
            //compute sum of: all input pubkeys + all input commitments
            for(loopVars[0] = 0; loopVars[0] < ringParams[0] - 1; loopVars[0]++) {
                if (point[0] == uint256(0)) {
                    (point[0], point[1]) = Secp256k1.decompressXY(utxos[_inputIDs[loopVars[0]*ringParams[1] + loopVars[1]]].keys[1].yBit%2,
                        utxos[_inputIDs[loopVars[0]*ringParams[1] + loopVars[1]]].keys[1].x);

                    uint256[2] memory commitment = Secp256k1.decompress(utxos[_inputIDs[loopVars[0]*ringParams[1] + loopVars[1]]].keys[0].yBit%2,
                        utxos[_inputIDs[loopVars[0]*ringParams[1] + loopVars[1]]].keys[0].x);

                    (point[0], point[1]) = Secp256k1.add(point[0], point[1], commitment[0], commitment[1]);
                } else {
                    uint256[2] memory temp = Secp256k1.decompress(utxos[_inputIDs[loopVars[0]*ringParams[1] + loopVars[1]]].keys[1].yBit%2,
                        utxos[_inputIDs[loopVars[0]*ringParams[1] + loopVars[1]]].keys[1].x);
                    (point[0], point[1]) = Secp256k1.add(point[0], point[1], temp[0], temp[1]);
                    temp = Secp256k1.decompress(utxos[_inputIDs[loopVars[0]*ringParams[1] + loopVars[1]]].keys[0].yBit%2,
                        utxos[_inputIDs[loopVars[0]*ringParams[1] + loopVars[1]]].keys[0].x);
                    (point[0], point[1]) = Secp256k1.add(point[0], point[1], temp[0], temp[1]);
                }
            }

            //(point[2], point[3]) = Secp256k1.decompressXY(uint8(pk[0])%2, convertBytes33ToUint(pk,  1, 32));
            (point[2], point[3]) = Secp256k1.sub(point[0], point[1], outSum[0], outSum[1]);
            (uint8 yBit, uint256 compressX) = Secp256k1.compressXY(point[2], point[3]);
            Bytes.copyTo(yBit + 2, compressX, fullRingCT, fullRingCTOffSet);
            fullRingCTOffSet += 33;
        }
        return fullRingCTOffSet;
    }


    /**Withdraw TOMO/Token privately without revealing which output is being spent
    *@param {_inputIDs} The index IDs of all decoys in all input rings, data is structured as [ring00,ring01,ring02,ring11...]
    *@param {_outputs} commitments, stealth addresses and transaction pubkeys of outputs produced by this private send
    *@param {_withdrawalAmount} the amount to be withdrawn
    *@param {_amounts} enrypted/encoded format of transaction outputs amounts and masks/blinding factors
    *@param {_recipient} the recipient of the withdrawing transaction
    *@param {_ringSignature} ring signature that will be verified by precompiled contract
    */
    function withdrawFunds(uint[] memory _inputIDs, //multiple rings
        uint256[] memory _outputs, //1/3 for commitments, 1/3 for stealths,, 1/3 for txpubs : only contain 1 output
        uint256 _withdrawalAmount,
        uint256[2] memory _amounts, // _amounts[0]: encrypted amount, _amounts[1]: encrypted mask
        address payable _recipient,
        bytes memory _ringSignature,
        bytes memory _bp,
        byte[137] memory _data) public {

        require(_recipient != address(0x0), "recipient address invalid");
        require(_inputIDs.length < 100, "too many inputs");
        require(_inputIDs.length > 0, "no inputs");
        require(_outputs.length % 6 == 0 && _outputs.length <= 2*6);
        require(1 == _outputs.length.div(6));

        //verify signature size
        require(_ringSignature.length > 16);
        //[0]: numRing
        //[1]: ringSize
        //[2]: public offset
        //[3]: key images offset
        uint256[4] memory ringParams;
        uint256[3] memory loopVars;
        ringParams[0] = CopyUtils.ConvertBytesToUint(_ringSignature, 0, 8);    //numRing
        ringParams[1] = CopyUtils.ConvertBytesToUint(_ringSignature, 8, 8);    //ringSize

        require(_inputIDs.length % (ringParams[1]) == 0);

        require(ComputeSignatureSize(ringParams[0], ringParams[1]) == _ringSignature.length + ringParams[0]*ringParams[1]*33);

        ringParams[2] = 80 + ringParams[0] * ringParams[1] *32;
        ringParams[3] = ringParams[2];

        //verify key image spend
        verifyKeyImageSpent(ringParams[0], _ringSignature, ringParams[3]);

        bytes memory fullRingCT = new bytes(ComputeSignatureSize(ringParams[0], ringParams[1]));
        uint256 fullRingCTOffSet = 0;
        //testing: copy entire _ring to fullRingCT
        Bytes.copySubstr(fullRingCT, 0, _ringSignature, 0, ringParams[2]);

        fullRingCTOffSet += ringParams[2];

        //verify public keys is correct, the number of pubkey inputs = ringParams[0] * ringParams[1]
        //pubkeys start from offset: 80 + ringParams[0] * ringParams[1] *32
        //this does not verify additional ring (the last ring)
        fullRingCTOffSet = copyRingKeys(fullRingCT, fullRingCTOffSet, _inputIDs, ringParams[0], ringParams[1]);

        //verify additional ring
        //compute sum of outputs
        uint256[2] memory outSum;
        //withdrawal amount + fee to commitment
        (outSum[0], outSum[1]) = Secp256k1.mulWithHToPoint(_withdrawalAmount.Wei2Gwei().add(FEE));

        (outSum[0], outSum[1]) = Secp256k1.add(outSum[0], outSum[1], _outputs[0], _outputs[1]);

        //compute additional ring
        fullRingCTOffSet = computeAdditionalRingKeys(_inputIDs, fullRingCT, ringParams, fullRingCTOffSet, outSum);

        //copy key images
        Bytes.copySubstr(fullRingCT, fullRingCTOffSet, _ringSignature, ringParams[3], ringParams[0]*33);

        //verify ringSignature
        require(VerifyRingCT(fullRingCT), "signature failed");

        //transfer
        _recipient.transfer(_withdrawalAmount);

        //transfer fee
        transferFee(FEE);

        uint256[3] memory X;
        uint8[3] memory yBit;
        (yBit[0], X[0]) = Secp256k1.compressXY(_outputs[0], _outputs[1]);
        //overwrite bulletproof range proof with commitment
        Bytes.copyTo(yBit[0] + 2, X[0], _bp, 4);
        //verify bulletproof
        require(VerifyRangeProof(_bp), "bulletproof verification failed");

        (yBit[1], X[1]) = Secp256k1.compressXY(_outputs[2], _outputs[3]);

        (yBit[2], X[2]) = Secp256k1.compressXY(_outputs[4], _outputs[5]);

        utxos.length = utxos.length + 1;
        utxos[utxos.length - 1].keys[0] = CompressPubKey(yBit[0] + 2, X[0]);
        utxos[utxos.length - 1].keys[1] = CompressPubKey(yBit[1] + 2, X[1]);
        utxos[utxos.length - 1].keys[2] = CompressPubKey(yBit[2] + 2, X[2]);
        utxos[utxos.length - 1].amount = _amounts[0];
        utxos[utxos.length - 1].mask = _amounts[1];
        utxos[utxos.length - 1].txID = txs.length;

        emit NewUTXO([utxos[utxos.length - 1].keys[0].x, utxos[utxos.length - 1].keys[1].x, utxos[utxos.length - 1].keys[2].x],
            [utxos[utxos.length - 1].keys[0].yBit, utxos[utxos.length - 1].keys[1].yBit, utxos[utxos.length - 1].keys[2].yBit],
            [utxos[utxos.length - 1].amount, utxos[utxos.length - 1].mask],
            utxos.length - 1,
            txs.length);
        addNewTransaction(_data, 1);
    }

    function transferFee(uint256 fee) internal {
        issuer().transfer(fee.Gwei2Wei());
        emit TransactionFee(issuer(), fee.Gwei2Wei());
    }

    function addNewTransaction(byte[137] memory _data, uint256 _numUTXO) internal {
        //emit new transaction
        txs.length = txs.length + 1;
        NewUTXOEventStruct[] memory newUTXOs = new NewUTXOEventStruct[](_numUTXO);
        for(uint i = utxos.length - _numUTXO; i < utxos.length; i++) {
            txs[txs.length - 1].utxoIndexes.push(i);
            txs[txs.length - 1].data = _data;

            newUTXOs[i + _numUTXO - utxos.length].Xs = [utxos[i].keys[0].x, utxos[i].keys[1].x, utxos[i].keys[2].x];
            newUTXOs[i + _numUTXO - utxos.length].YBits = [utxos[i].keys[0].yBit, utxos[i].keys[1].yBit, utxos[i].keys[2].yBit];
            newUTXOs[i + _numUTXO - utxos.length].amount = [utxos[i].amount, utxos[i].mask];
            newUTXOs[i + _numUTXO - utxos.length].index = i;
            newUTXOs[i + _numUTXO - utxos.length].txIndex = txs.length - 1;
        }

        emit NewTransaction(
            txs.length - 1, newUTXOs, _data
        );
    }

    function getTransaction(uint256 _index) public view returns (uint256, NewUTXOEventStruct[] memory, byte[137] memory) {
        uint256 numUTXO = txs[_index].utxoIndexes.length;
        NewUTXOEventStruct[] memory retUTXOs = new NewUTXOEventStruct[](numUTXO);
        uint256[] storage utxoIndexes = txs[_index].utxoIndexes;
        for(uint i = 0; i < numUTXO; i++) {
            UTXO storage utxo = utxos[utxoIndexes[i]];
            retUTXOs[i].Xs = [utxo.keys[0].x, utxo.keys[1].x, utxo.keys[2].x];
            retUTXOs[i].YBits = [utxo.keys[0].yBit, utxo.keys[1].yBit, utxo.keys[2].yBit];
            retUTXOs[i].amount = [utxo.amount, utxo.mask];
            retUTXOs[i].index = utxoIndexes[i];
            retUTXOs[i].txIndex = _index;
        }

        return (_index, retUTXOs, txs[_index].data);
    }

    function getTransactions(uint256[] memory _indexes) public view returns (uint256[] memory, NewUTXOEventStruct[] memory, byte[] memory) {
        uint256 numUTXO = 0;
        uint256 numValidTx = 0;
        uint256 utxoIterator = 0;
        for(uint i = 0; i < _indexes.length; i++) {
            if (_indexes[i] >= txs.length) break;
            numUTXO += txs[_indexes[i]].utxoIndexes.length;
            numValidTx++;
        }
        NewUTXOEventStruct[] memory retUTXOs = new NewUTXOEventStruct[](numUTXO);
        byte[] memory data = new byte[](numValidTx*137);
        for(uint i = 0; i < _indexes.length; i++) {
            if (_indexes[i] >= txs.length) break;
            uint256 txNumUTXO = txs[i].utxoIndexes.length;
            uint256[] storage utxoIndexes = txs[i].utxoIndexes;
            for(uint j = 0; j < txNumUTXO; j++) {
                UTXO storage utxo = utxos[utxoIndexes[j]];
                retUTXOs[utxoIterator].Xs = [utxo.keys[0].x, utxo.keys[1].x, utxo.keys[2].x];
                retUTXOs[utxoIterator].YBits = [utxo.keys[0].yBit, utxo.keys[1].yBit, utxo.keys[2].yBit];
                retUTXOs[utxoIterator].amount = [utxo.amount, utxo.mask];
                retUTXOs[utxoIterator].index = utxoIndexes[j];
                retUTXOs[utxoIterator].txIndex = utxo.txID;
                utxoIterator++;
            }

            for(uint k = 0; k < 137; k++) {
                data[i*137 + k] = txs[i].data[k];
            }
        }

        return (_indexes, retUTXOs, data);
    }

    function getUTXO(uint256 index) public view returns (uint256[3] memory,
        uint8[3] memory,
        uint256[2] memory //0. encrypted amount, 1. encrypted mask
    ) {
        return (
        [utxos[index].keys[0].x, utxos[index].keys[1].x, utxos[index].keys[2].x],
        [utxos[index].keys[0].yBit, utxos[index].keys[1].yBit, utxos[index].keys[2].yBit],
        [utxos[index].amount,utxos[index].mask]
        );
    }

    function getUTXOs(uint256[] memory indexs) public view returns (RawUTXO[] memory) {
        RawUTXO[] memory utxs = new RawUTXO[](indexs.length);
        // just a limit each request
        require(indexs.length < 50);

        for(uint8 i = 0; i < indexs.length; i++) {
            uint256 index = indexs[i];
            // utxs.length += 1;
            RawUTXO memory utxo = utxs[i];
            if (utxos.length <= index) {
                return utxs;
            }
            utxo.XBits = [utxos[index].keys[0].x, utxos[index].keys[1].x, utxos[index].keys[2].x];
            utxo.YBits = [utxos[index].keys[0].yBit, utxos[index].keys[1].yBit, utxos[index].keys[2].yBit];
            utxo.encodeds = [utxos[index].amount, utxos[index].mask];
        }

        return utxs;
    }

    function getTxs(uint256[] memory indexs) public view returns (Transaction[] memory) {
        Transaction[] memory result_txs = new Transaction[](indexs.length);
        // just a limit each request
        require(indexs.length < 50);

        for(uint8 i = 0; i < indexs.length; i++) {
            uint256 index = indexs[i];

            Transaction memory tx = result_txs[i];
            if (txs.length <= index) {
                return result_txs;
            }
            tx.utxoIndexes = txs[index].utxoIndexes;
            tx.data = txs[index].data;
        }

        return result_txs;
    }

    function getLatestTx() public view returns (uint) {
        return txs.length;
    }

    function isSpent(byte[] memory keyImage) public view returns (bool) {
        uint256 kiHash = CopyUtils.BytesToUint(keccak256(abi.encodePacked(keyImage)));
        return keyImagesMapping[kiHash];
    }

        function areSpent(bytes memory keyImages) public view returns (bool[] memory) {
            require(keyImages.length < 50 * 33);

            uint256 numberKeyImage = keyImages.length / 33;
            bool[] memory result = new bool[](numberKeyImage);

            for(uint256 i = 0; i < numberKeyImage; i++) {
                (bool success, byte[33] memory ki) = CopyUtils.Copy33Bytes(keyImages, i*33);
                require(success);
                uint256 kiHash = CopyUtils.BytesToUint(keccak256(abi.encodePacked(ki)));
                result[i] = keyImagesMapping[kiHash];
            }

            return result;
        }

    //dont receive any money via default callback
    function () external payable {
        revert();
    }
}
