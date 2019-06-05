pragma solidity ^0.5.0;


/**
 * @title ECRecovery
 * @dev Elliptic curve signature operations.
 * Based off of https://github.com/OpenZeppelin/openzeppelin-solidity/blob/master/contracts/ECRecovery.sol.
 */
library ECRecovery {
    /*
     * Internal functions
     */

    /**
     * @dev Given a hash and a signature, returns the address of the signee.
     * @param _hash Hash that was signed.
     * @param _sig Signature over the hash.
     * @return Address of the signee.
     */
    function recover(bytes32 _hash, bytes memory _sig)
        internal
        pure
        returns (address)
    {
        bytes32 r;
        bytes32 s;
        uint8 v;

        // Check the signature length.
        require(_sig.length == 65, "sig length incorrect");

        // Divide the signature in v, r, and s variables.
        assembly {
            r := mload(add(_sig, 32))
            s := mload(add(_sig, 64))
            v := byte(0, mload(add(_sig, 96)))
        }

        // Version of signature should be 27 or 28, but 0 and 1 are also possible versions.
        if (v < 27) {
            v += 27;
        }

        // If the version is correct return the signer address.
        require(v == 27 || v == 28, "wrong v value");

        address result = ecrecover(_hash, v, r, s);
        require(result != address(0), "empty result");

        return result;
    }
}
