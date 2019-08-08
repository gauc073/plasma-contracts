pragma solidity ^0.5.0;
pragma experimental ABIEncoderV2;

import "./PaymentExitDataModel.sol";
import "./spendingConditions/IPaymentSpendingCondition.sol";
import "./spendingConditions/PaymentSpendingConditionRegistry.sol";
import "../IOutputGuardParser.sol";
import "../OutputGuardParserRegistry.sol";
import "../utils/ExitId.sol";
import "../utils/ExitableTimestamp.sol";
import "../utils/OutputId.sol";
import "../utils/OutputGuard.sol";
import "../../framework/PlasmaFramework.sol";
import "../../framework/interfaces/IExitProcessor.sol";
import "../../utils/Bits.sol";
import "../../utils/IsDeposit.sol";
import "../../utils/OnlyWithValue.sol";
import "../../utils/UtxoPosLib.sol";
import "../../utils/Merkle.sol";
import "../../transactions/PaymentTransactionModel.sol";
import "../../transactions/outputs/PaymentOutputModel.sol";

contract PaymentInFlightExitable is
    IExitProcessor,
    OnlyWithValue,
    OutputGuardParserRegistry,
    PaymentSpendingConditionRegistry
{
    using ExitableTimestamp for ExitableTimestamp.Calculator;
    using IsDeposit for IsDeposit.Predicate;
    using PaymentOutputModel for PaymentOutputModel.Output;
    using RLP for bytes;
    using RLP for RLP.RLPItem;
    using UtxoPosLib for UtxoPosLib.UtxoPos;
    using PaymentExitDataModel for PaymentExitDataModel.InFlightExit;

    uint8 constant public MAX_INPUT_NUM = 4;
    uint8 constant public MAX_OUTPUT_NUM = 4;
    uint256 public constant IN_FLIGHT_EXIT_BOND = 31415926535 wei;
    uint256 public PIGGYBACK_BOND = 31415926535 wei;

    mapping (uint192 => PaymentExitDataModel.InFlightExit) public inFlightExits;

    PlasmaFramework private framework;
    IsDeposit.Predicate private isDeposit;
    ExitableTimestamp.Calculator private exitableTimestampCalculator;
    uint256 private minExitPeriod;

    event InFlightExitStarted(
        address indexed initiator,
        bytes32 txHash
    );

    event InFlightExitPiggybacked(
        address indexed owner,
        bytes32 txHash,
        uint16 index,
        bool isInput
    );

    /**
    * @notice Wraps arguments for startInFlightExit.
    * @param inFlightTx RLP encoded in-flight transaction.
    * @param inputTxs Transactions that created the inputs to the in-flight transaction. In the same order as in-flight transaction inputs.
    * @param inputUtxosPos Utxos that represent in-flight transaction inputs. In the same order as input transactions.
    * @param inputUtxosTypes Output types of in flight transaction inputs. In the same order as input transactions.
    * @param inputTxsInclusionProofs Merkle proofs that show the input-creating transactions are valid. In the same order as input transactions.
    * @param inFlightTxWitnesses Witnesses for in-flight transaction. In the same order as input transactions.
    */
    struct StartExitArgs {
        bytes inFlightTx;
        bytes[] inputTxs;
        uint256[] inputUtxosPos;
        uint256[] inputUtxosTypes;
        bytes[] inputTxsInclusionProofs;
        bytes[] inFlightTxWitnesses;
    }

    /**
     * @dev data to be passed around start in-flight exit helper functions
     * @param exitId ID of the exit.
     * @param inFlightTxRaw In-flight transaction as bytes.
     * @param inFlightTx Decoded in-flight transaction.
     * @param inFlightTxHash Hash of in-flight transaction.
     * @param inputTxsRaw Input transactions as bytes.
     * @param inputTxs Decoded input transactions.
     * @param inputUtxosPos Postions of input utxos.
     * @param inputUtxosTypes Types of outputs that make in-flight transaction inputs.
     * @param inputTxsInclusionProofs Merkle proofs for input transactions.
     * @param inFlightTxWitnesses Witnesses for in-flight transactions.
     * @param outputIds Output ids for input transactions.
     */
    struct StartExitData {
        uint192 exitId;
        bytes inFlightTxRaw;
        PaymentTransactionModel.Transaction inFlightTx;
        bytes32 inFlightTxHash;
        bytes[] inputTxsRaw;
        PaymentTransactionModel.Transaction[] inputTxs;
        UtxoPosLib.UtxoPos[] inputUtxosPos;
        uint256[] inputUtxosTypes;
        bytes[] inputTxsInclusionProofs;
        bytes[] inFlightTxWitnesses;
        bytes32[] outputIds;
    }

    constructor(PlasmaFramework _framework) public {
        framework = _framework;
        isDeposit = IsDeposit.Predicate(framework.CHILD_BLOCK_INTERVAL());
        exitableTimestampCalculator = ExitableTimestamp.Calculator(framework.minExitPeriod());
        minExitPeriod = framework.minExitPeriod();
    }

    /**
     * @notice Starts withdrawal from a transaction that might be in-flight.
     * @dev requires the exiting UTXO's token to be added via 'addToken'
     * @dev Uses struct as input because too many variables and failed to compile.
     * @dev Uses public instead of external because ABIEncoder V2 does not support struct calldata + external
     * @param args input argument data to challenge. See struct 'StartExitArgs' for detailed info.
     */
    function startInFlightExit(StartExitArgs memory args) public payable onlyWithValue(IN_FLIGHT_EXIT_BOND) {
        StartExitData memory startExitData = createStartExitData(args);
        verifyStart(startExitData);
        startExit(startExitData);
        emit InFlightExitStarted(msg.sender, startExitData.inFlightTxHash);
    }

    /**
     * @notice Allows a user to piggyback onto an in-flight transaction.
     * @dev requires the exiting UTXO's token to be added via `addToken`
     * @param _inFlightTx RLP encoded in-flight transaction.
     * @param _outputType Specific type of the output.
     * @param _outputGuardData (Optional) Output guard data if the output type is not 0.
     * @param _index Index of the input/output to piggyback.
     * @param _isInput To determine this is an action of piggyback on transaction input or output.
     */
    function piggybackInFlightExit(
        bytes calldata _inFlightTx,
        uint256 _outputType,
        bytes calldata _outputGuardData,
        uint16 _index,
        bool _isInput
    )
        external
        payable
        onlyWithValue(PIGGYBACK_BOND)
    {
        if (_isInput) {
            require(_index < MAX_INPUT_NUM, "Index exceed max size of input");
        } else {
            require(_index < MAX_OUTPUT_NUM, "Index exceed max size of output");
        }

        uint192 exitId = ExitId.getInFlightExitId(_inFlightTx);
        PaymentExitDataModel.InFlightExit storage exit = inFlightExits[exitId];

        require(exit.exitStartTimestamp != 0, "No inflight exit to piggyback on");
        require(exit.isInFirstPhase(minExitPeriod), "Can only piggyback in first phase of exit period");
        require(!exit.isPiggybacked(_index, _isInput), "The indexed input/output has been piggybacked already");

        PaymentExitDataModel.WithdrawData memory withdrawData;
        if (_isInput) {
            withdrawData = exit.inputs[_index];
            require(withdrawData.exitTarget == msg.sender, "Can be called by the exit target of input only");
        } else {
            PaymentOutputModel.Output memory output = PaymentTransactionModel.decode(_inFlightTx).outputs[_index];
            address payable exitTarget;
            if (_outputType == 0) {
                exitTarget = output.owner();
            } else {
                require(
                    OutputGuard.build(_outputType, _outputGuardData) == output.outputGuard,
                    "Output guard data and output type from args mismatch with the outputguard in output"
                );

                IOutputGuardParser outputGuardParser = OutputGuardParserRegistry.outputGuardParsers(_outputType);
                require(address(outputGuardParser) != address(0), "Does not have outputGuardParser for the output type");

                exitTarget = outputGuardParser.parseExitTarget(_outputGuardData);
            }
            withdrawData = PaymentExitDataModel.WithdrawData({
                exitTarget: exitTarget,
                token: output.token,
                amount: output.amount
            });

            require(withdrawData.exitTarget == msg.sender, "Can be called by the exit target of output only");

            // output is set on piggyback to save some gas as output is always together with tx
            exit.outputs[_index] = withdrawData;
        }

        if (exit.isFirstPiggybackOfTheToken(withdrawData.token)) {
            UtxoPosLib.UtxoPos memory utxoPos = UtxoPosLib.UtxoPos(exit.position);
            (, uint256 blockTimestamp) = framework.blocks(utxoPos.blockNum());
            bool isPositionDeposit = isDeposit.test(utxoPos.blockNum());
            uint64 exitableAt = exitableTimestampCalculator.calculate(now, blockTimestamp, isPositionDeposit);

            framework.enqueue(withdrawData.token, exitableAt, utxoPos.txPos(), exitId, this);
        }

        exit.setPiggybacked(_index, _isInput);

        emit InFlightExitPiggybacked(msg.sender, keccak256(_inFlightTx), _index, _isInput);
    }

    function createStartExitData(StartExitArgs memory args) private view returns (StartExitData memory) {
        StartExitData memory exitData;
        exitData.exitId = ExitId.getInFlightExitId(args.inFlightTx);
        exitData.inFlightTxRaw = args.inFlightTx;
        exitData.inFlightTx = PaymentTransactionModel.decode(args.inFlightTx);
        exitData.inFlightTxHash = keccak256(args.inFlightTx);
        exitData.inputTxsRaw = args.inputTxs;
        exitData.inputTxs = decodeInputTxs(exitData.inputTxsRaw);
        exitData.inputUtxosPos = decodeInputTxsPositions(args.inputUtxosPos);
        exitData.inputUtxosTypes = args.inputUtxosTypes;
        exitData.inputTxsInclusionProofs = args.inputTxsInclusionProofs;
        exitData.inFlightTxWitnesses = args.inFlightTxWitnesses;
        exitData.outputIds = getOutputIds(exitData.inputTxsRaw, exitData.inputUtxosPos);
        return exitData;
    }

    function decodeInputTxsPositions(uint256[] memory inputUtxosPos) private pure returns (UtxoPosLib.UtxoPos[] memory) {
        require(inputUtxosPos.length <= MAX_INPUT_NUM, "To many input transactions provided");

        UtxoPosLib.UtxoPos[] memory utxosPos = new UtxoPosLib.UtxoPos[](inputUtxosPos.length);
        for (uint i = 0; i < inputUtxosPos.length; i++) {
            utxosPos[i] = UtxoPosLib.UtxoPos(inputUtxosPos[i]);
        }
        return utxosPos;
    }

    function decodeInputTxs(bytes[] memory inputTxsRaw) private pure returns (PaymentTransactionModel.Transaction[] memory) {
        PaymentTransactionModel.Transaction[] memory inputTxs = new PaymentTransactionModel.Transaction[](inputTxsRaw.length);
        for (uint i = 0; i < inputTxsRaw.length; i++) {
            inputTxs[i] = PaymentTransactionModel.decode(inputTxsRaw[i]);
        }
        return inputTxs;
    }

    function getOutputIds(bytes[] memory inputTxs, UtxoPosLib.UtxoPos[] memory utxoPos) private view returns (bytes32[] memory) {
        require(inputTxs.length == utxoPos.length, "Number of input transactions does not match number of provided input utxos positions");
        bytes32[] memory outputIds = new bytes32[](inputTxs.length);
        for (uint i = 0; i < inputTxs.length; i++) {
            bool isDepositTx = isDeposit.test(utxoPos[i].blockNum());
            outputIds[i] = isDepositTx ?
                OutputId.computeDepositOutputId(inputTxs[i], utxoPos[i].outputIndex(), utxoPos[i].value)
                : OutputId.computeNormalOutputId(inputTxs[i], utxoPos[i].outputIndex());
        }
        return outputIds;
    }

    function verifyStart(StartExitData memory exitData) private view {
        verifyExitNotStarted(exitData.exitId);
        verifyNumberOfInputsMatchesNumberOfInFlightTransactionInputs(exitData);
        verifyNoInputSpentMoreThanOnce(exitData.inFlightTx);
        verifyInputTransactionsInludedInPlasma(exitData);
        verifyInputsSpendingCondition(exitData);
        verifyInFlightTransactionDoesNotOverspend(exitData);
    }

    function verifyExitNotStarted(uint192 exitId) private view {
        PaymentExitDataModel.InFlightExit storage exit = inFlightExits[exitId];
        require(exit.exitStartTimestamp == 0, "There is an active in-flight exit from this transaction");
        require(!exit.isFinalized(), "This in-flight exit has already been finalized");
    }

    function verifyNumberOfInputsMatchesNumberOfInFlightTransactionInputs(StartExitData memory exitData) private pure {
        require(
            exitData.inputTxs.length == exitData.inFlightTx.inputs.length,
            "Number of input transactions does not match number of in-flight transaction inputs"
        );
        require(
            exitData.inputUtxosPos.length == exitData.inFlightTx.inputs.length,
            "Number of input transactions positions does not match number of in-flight transaction inputs"
        );
        require(
            exitData.inputUtxosTypes.length == exitData.inFlightTx.inputs.length,
            "Number of input utxo types does not match number of in-flight transaction inputs"
        );
        require(
            exitData.inputTxsInclusionProofs.length == exitData.inFlightTx.inputs.length,
            "Number of input transactions inclusion proofs does not match number of in-flight transaction inputs"
        );
        require(
            exitData.inFlightTxWitnesses.length == exitData.inFlightTx.inputs.length,
            "Number of input transactions witnesses does not match number of in-flight transaction inputs"
        );
    }

    function verifyNoInputSpentMoreThanOnce(PaymentTransactionModel.Transaction memory inFlightTx) private pure {
        if (inFlightTx.inputs.length > 1) {
            for (uint i = 0; i < inFlightTx.inputs.length; i++) {
                for (uint j = i + 1; j < inFlightTx.inputs.length; j++) {
                    require(inFlightTx.inputs[i] != inFlightTx.inputs[j], "In-flight transaction must have unique inputs");
                }
            }
        }
    }

    function verifyInputTransactionsInludedInPlasma(StartExitData memory exitData) private view {
        for (uint i = 0; i < exitData.inputTxs.length; i++) {
            (bytes32 root, ) = framework.blocks(exitData.inputUtxosPos[i].blockNum());
            bytes32 leaf = keccak256(exitData.inputTxsRaw[i]);
            require(
                Merkle.checkMembership(leaf, exitData.inputUtxosPos[i].txIndex(), root, exitData.inputTxsInclusionProofs[i]),
                "Input transaction is not included in plasma"
            );
        }
    }

    function verifyInputsSpendingCondition(StartExitData memory exitData) private view {
        for (uint i = 0; i < exitData.inputTxs.length; i++) {
            uint16 outputIndex = exitData.inputUtxosPos[i].outputIndex();
            bytes32 outputGuard = exitData.inputTxs[i].outputs[outputIndex].outputGuard;

            //FIXME: consider moving spending conditions to PlasmaFramework
            IPaymentSpendingCondition condition = PaymentSpendingConditionRegistry.spendingConditions(
                exitData.inputUtxosTypes[i], exitData.inFlightTx.txType);
            require(address(condition) != address(0), "Spending condition contract not found");

            bool isSpentByInFlightTx = condition.verify(
                outputGuard,
                exitData.inputUtxosPos[i].value,
                exitData.outputIds[i],
                exitData.inFlightTxRaw,
                uint8(i),
                exitData.inFlightTxWitnesses[i]
            );
            require(isSpentByInFlightTx, "Spending condition failed");
        }
    }

    function verifyInFlightTransactionDoesNotOverspend(StartExitData memory exitData) private pure {
        PaymentTransactionModel.Transaction memory inFlightTx = exitData.inFlightTx;
        for (uint i = 0; i < inFlightTx.outputs.length; i++) {
            address token = inFlightTx.outputs[i].token;
            uint256 tokenAmountOut = getTokenAmountOut(inFlightTx, token);
            uint256 tokenAmountIn = getTokenAmountIn(exitData.inputTxs, exitData.inputUtxosPos, token);
            require(tokenAmountOut <= tokenAmountIn, "Invalid transaction, spends more than provided in inputs");
        }
    }

    function getTokenAmountOut(PaymentTransactionModel.Transaction memory inFlightTx, address token) private pure returns (uint256) {
        uint256 amountOut = 0;
        for (uint i = 0; i < inFlightTx.outputs.length; i++) {
            if (inFlightTx.outputs[i].token == token) {
                amountOut += inFlightTx.outputs[i].amount;
            }
        }
        return amountOut;
    }

    function getTokenAmountIn(
        PaymentTransactionModel.Transaction[] memory inputTxs,
        UtxoPosLib.UtxoPos[] memory inputUtxosPos,
        address token
    )
        private
        pure
        returns (uint256)
    {
        uint256 amountIn = 0;
        for (uint i = 0; i < inputTxs.length; i++) {
            uint16 oindex = inputUtxosPos[i].outputIndex();
            PaymentOutputModel.Output memory output = inputTxs[i].outputs[oindex];
            if (output.token == token) {
                amountIn += output.amount;
            }
        }
        return amountIn;
    }

    function startExit(StartExitData memory startExitData) private {
        PaymentExitDataModel.InFlightExit storage ife = inFlightExits[startExitData.exitId];
        ife.bondOwner = msg.sender;
        ife.position = getYoungestInputUtxoPosition(startExitData.inputUtxosPos);
        ife.exitStartTimestamp = block.timestamp;
        setInFlightExitInputs(ife, startExitData.inputTxs, startExitData.inputUtxosPos);
        // output is set during a piggyback
    }

    function getYoungestInputUtxoPosition(UtxoPosLib.UtxoPos[] memory inputUtxosPos) private pure returns (uint256) {
        uint256 youngest = inputUtxosPos[0].value;
        for (uint i = 1; i < inputUtxosPos.length; i++) {
            if (inputUtxosPos[i].value > youngest) {
                youngest = inputUtxosPos[i].value;
            }
        }
        return youngest;
    }

    function setInFlightExitInputs(
        PaymentExitDataModel.InFlightExit storage ife,
        PaymentTransactionModel.Transaction[] memory inputTxs,
        UtxoPosLib.UtxoPos[] memory inputUtxosPos
    )
        private
    {
        for (uint i = 0; i < inputTxs.length; i++) {
            uint16 outputIndex = inputUtxosPos[i].outputIndex();
            PaymentOutputModel.Output memory output = inputTxs[i].outputs[outputIndex];
            ife.inputs[i].exitTarget = output.owner();
            ife.inputs[i].token = output.token;
            ife.inputs[i].amount = output.amount;
        }
    }
}
