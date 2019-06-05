pragma solidity ^0.5.0;
pragma experimental ABIEncoderV2;

import "./OnlyFramework.sol";
import "../models/FundingExitDataModel.sol";
import "../../WithFramework.sol";
import "../../vaults/EthVault.sol";

contract FundingExitProcessor {
    uint256 constant TX_TYPE = 2;

    PlasmaFramework framework;
    EthVault ethVault;

    modifier onlyFramework() {
        require(msg.sender == address(framework), "Not being called from the PlasmaFramework");
        _;
    }

    constructor(address _framework, address _ethVault) public {
        framework = PlasmaFramework(_framework);
        ethVault = EthVault(_ethVault);
    }

    function processExit(uint256 _exitId) external onlyFramework {
        bytes memory exitDataInBytes = framework.getBytesStorage(TX_TYPE, bytes32(_exitId));
        FundingExitDataModel.Data memory exitData = abi.decode(exitDataInBytes, (FundingExitDataModel.Data));

        if (exitData.exitable && exitData.token == address(0)) {
            ethVault.withdraw(exitData.exitTarget, exitData.amount);
        }
    }
}
