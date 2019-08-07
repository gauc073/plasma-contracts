from eth_tester.exceptions import TransactionFailed
from web3.contract import Contract


class ConvenienceContractWrapper:

    def __init__(self, contract: Contract):
        self.contract = contract

    def __getattr__(self, item):
        method = self._find_abi_method(item)
        if method:
            function = self.contract.functions.__getattribute__(item)
            return ConvenienceContractWrapper._call_or_transact(function, method)

        return self.contract.__getattribute__(item)

    def _find_abi_method(self, item):
        for i in self.contract.abi:
            if i['type'] == 'function' and i['name'] == item:
                return i

    @staticmethod
    def _call_or_transact(function, method_abi):
        def _do_call(*args):
            return function(*args).call()

        def _do_transact(*args, **kwargs):
            # params = {**ContractConvenienceWrapper.default_params, **kwargs}
            tx_hash = function(*args).transact(kwargs)

            if function.web3.eth.getTransactionReceipt(tx_hash).status == 0:
                raise TransactionFailed

            return tx_hash

        if method_abi['constant']:
            return _do_call
        else:
            return _do_transact