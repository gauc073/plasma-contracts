pragma solidity ^0.5.0;

import '../../transactions/outputs/PaymentOutputModel.sol';
import '../../transactions/PaymentTransactionModel.sol';
import "../../utils/Bits.sol";

library PaymentExitDataModel {
    using Bits for uint256;

    uint8 constant public MAX_INPUT_NUM = 4;
    uint8 constant public MAX_OUTPUT_NUM = 4;

    struct StandardExit {
        bool exitable;
        uint192 utxoPos;
        bytes32 outputId;
        // Hash of output type and output guard.
        // Correctness of them would be checked when exit starts.
        // For other steps, they just check data consistency of input args.
        bytes32 outputTypeAndGuardHash;
        address token;
        address payable exitTarget;
        uint256 amount;
    }

    struct WithdrawData {
        address payable exitTarget;
        address token;
        uint256 amount;
    }

    struct InFlightExit {
        uint256 exitStartTimestamp;
        // exit map stores piggybacks and finalized exits
        // bit 255 is set only when ife has finalized
        // input is piggybacked only when input number bit is set
        // output is piggybacked only when MAX_INPUTS + output number bit is set
        // input is exited only when 2 * MAX_INPUTS + input number bit is set
        // output is exited only when 3 * MAX_INPUTS + output number bit is set
        uint256 exitMap;
        uint256 position;
        WithdrawData[MAX_INPUT_NUM] inputs;
        WithdrawData[MAX_OUTPUT_NUM] outputs;
        address payable bondOwner;
        uint256 oldestCompetitorPosition;
    }

    function setPiggybacked(InFlightExit storage ife, uint16 index, bool isInput) internal {
        uint8 indexInExitMap = isInput? uint8(index) : uint8(index + MAX_INPUT_NUM);
        ife.exitMap = ife.exitMap.setBit(indexInExitMap);
    }

    function isInFirstPhase(InFlightExit storage ife, uint256 minExitPeriod)
        internal
        view
        returns (bool)
    {
        uint256 periodTime = minExitPeriod / 2;
        return ((block.timestamp - ife.exitStartTimestamp) / periodTime) < 1;
    }

    function isPiggybacked(InFlightExit storage ife, uint16 index, bool isInput)
        internal
        view
        returns (bool)
    {
        uint8 indexInExitMap = isInput? uint8(index) : uint8(index + MAX_INPUT_NUM);
        return ife.exitMap.bitSet(indexInExitMap);
    }

    function isFinalized(PaymentExitDataModel.InFlightExit storage ife)
        internal
        view
        returns (bool)
    {
        return Bits.bitSet(ife.exitMap, 255);
    }

    function isFirstPiggybackOfTheToken(InFlightExit storage ife, address token)
        internal
        view
        returns (bool)
    {
        for (uint i = 0 ; i < MAX_INPUT_NUM ; i++) {
            if (isPiggybacked(ife, uint16(i), true) && ife.inputs[i].token == token) {
                return false;
            }
        }

        for (uint i = 0 ; i < MAX_OUTPUT_NUM ; i++) {
            if (isPiggybacked(ife, uint16(i), false) && ife.outputs[i].token == token) {
                return false;
            }
        }

        return true;
    }
}
