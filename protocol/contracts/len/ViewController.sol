// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ChainType} from "../libs/Types.sol";
import {IGasService} from "../interfaces/IGasService.sol";
import {IVaultManager} from "../interfaces/IVaultManager.sol";
import {IRelay} from "../interfaces/IRelay.sol";
import {IMintAbleChecker} from "../interfaces/IMintAbleChecker.sol";
import {IAffiliateFeeManager} from "../interfaces/affiliate/IAffiliateFeeManager.sol";
import {IRegistry, ContractType, ChainType, GasInfo} from "../interfaces/IRegistry.sol";
import {ITSSManager} from "../interfaces/ITSSManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseImplementation} from "@mapprotocol/common-contracts/contracts/base/BaseImplementation.sol";

contract ViewController is BaseImplementation {
    uint256 public immutable selfChainId = block.chainid;
    uint256 constant MAX_RATE_UNIT = 1_000_000;         // unit is 0.01 bps

    IRegistry public registry;

    event SetRegistry(address _registry);

    function initialize(address _defaultAdmin) public initializer {
        __BaseImplementation_init(_defaultAdmin);
    }

    function setRegistry(address _registry) external restricted {
        require(_registry != address(0));
        registry = IRegistry(_registry);
        emit SetRegistry(_registry);
    }

    function getLastTxOutHeight() external view returns (uint256) {
        IRelay relay = _getRelay();
        return relay.getChainLastScanBlock(selfChainId);
    }

    function getLastTxInHeight(uint256 chain) external view returns (uint256) {
        IRelay relay = _getRelay();
        return relay.getChainLastScanBlock(chain);
    }

    struct VaultRouter {
        uint256 chain;
        bytes router;
    }
    struct VaultInfo {
        bytes pubkey;
        VaultRouter[] routers;
    }


    function getPublicKeys() external view returns(VaultInfo[] memory infos) {
        IVaultManager vm = _getVaultManager();
        IRegistry r = registry;
        uint256[] memory chains = vm.getBridgeChains();
        bytes memory active = vm.getActiveVault();
        bytes memory retiring = vm.getRetiringVault();
        if(retiring.length > 0) {
            infos = new VaultInfo[](2);
            infos[0] = _getVaultInfo(r, chains, active);
            infos[1] = _getVaultInfo(r, chains, retiring);
        } else {
            infos = new VaultInfo[](1);
            infos[0] = _getVaultInfo(r, chains, active);
        }
    }

    function _getVaultInfo(IRegistry r, uint256[] memory chains, bytes memory pubkey) internal view  returns (VaultInfo memory info) {
        uint256 len = chains.length;
        info.pubkey = pubkey;
        info.routers = new VaultRouter[](len);
        for (uint i = 0; i < len; i++) {
            uint256 chain = chains[i];
            info.routers[i].chain = chain;
            if(r.getChainType(chain) == ChainType.CONTRACT) {
                info.routers[i].router = r.getChainRouters(chain);
            } else {
                info.routers[i].router = pubkey;
            }
        }
    }

    struct InboundAddress {
        uint256 chain;
        bytes pubkey;
        bytes router;
        uint256 gasRate;
        uint256 txSize;
        uint256 txSizeWithCall;
    }

    function getInboundAddress() external view returns (InboundAddress[] memory inbounds) {
        IVaultManager vm = _getVaultManager();
        IRegistry r = registry;
        IGasService g = _getGasService();
        uint256[] memory chains = r.getChains();
        bytes memory active = vm.getActiveVault();
        uint256 len = chains.length;
        inbounds = new InboundAddress[](len);
        for (uint i = 0; i < len; i++) {
            uint256 chain = chains[i];
            inbounds[i].pubkey = active;
            inbounds[i].chain = chain;
            if(r.getChainType(chain) == ChainType.CONTRACT) {
                inbounds[i].router = r.getChainRouters(chain);
            } else {
                inbounds[i].router = active;
            }
            (inbounds[i].gasRate, inbounds[i].txSize, inbounds[i].txSizeWithCall) = g.getNetworkFeeInfo(chain);
        }
    }

    struct Token {
        bytes token;
        int256 balance;
        uint256 pendingOut;
        uint256 decimals;
    }
    struct RouterTokens {
        uint256 chain;
        bytes router;
        Token[] coins;
    }
    struct VaultView {
        bytes pubKey;
        address[] members;
        uint256[] chains;
        RouterTokens[] routerTokens;
    }

    function getVault(bytes calldata pubkey) external view returns (VaultView memory vaultView) {

        IRegistry r = registry;
        vaultView.pubKey = pubkey;

        IVaultManager vm = _getVaultManager();
        vaultView.chains = vm.getBridgeChains();
        vaultView.members = _getMembers(pubkey);
        address[] memory tokens = vm.getBridgeTokens();

        uint256 tokenLen = tokens.length;
        uint256 len = vaultView.chains.length;
        vaultView.routerTokens = new RouterTokens[](len);

        for (uint i = 0; i < len; i++) {
            uint256 chain = vaultView.chains[i];
            vaultView.routerTokens[i].chain = chain;
            if(r.getChainType(chain) == ChainType.CONTRACT) {
                vaultView.routerTokens[i].router = r.getChainRouters(chain);
            } else {
                vaultView.routerTokens[i].router = pubkey;
            }

            vaultView.routerTokens[i].coins = new Token[](tokenLen);
            for (uint j = 0; j < tokenLen; j++) {
                bytes memory toChainToken = r.getToChainToken(tokens[j], chain);
                vaultView.routerTokens[i].coins[j].token = toChainToken;
                if(chain == selfChainId) {
                    vaultView.routerTokens[i].coins[j].decimals = 18;
                    (vaultView.routerTokens[i].coins[j].balance, vaultView.routerTokens[i].coins[j].pendingOut) = vm.getVaultTokenBalance(pubkey, chain, tokens[j]);
                } else {
                    if(toChainToken.length > 0) {
                        vaultView.routerTokens[i].coins[j].decimals = r.getTokenDecimals(chain, toChainToken);
                        (int256 balance, uint256 pendingOut) = vm.getVaultTokenBalance(pubkey, chain, tokens[j]);
                        vaultView.routerTokens[i].coins[j].balance = _adjustDecimalsInt256(balance, vaultView.routerTokens[i].coins[j].decimals);
                        vaultView.routerTokens[i].coins[j].pendingOut = _adjustDecimals(pendingOut, vaultView.routerTokens[i].coins[j].decimals);
                    }
                }
            }
        }
    }

    struct QuoteResult {
        uint256 affiliateFee;
        uint256 protocolFee;
        uint256 fromVaultFee;
        uint256 toVaultFee;
        int256 inTokenBalanceFee;
        int256 outTokenBalanceFee;
        uint256 ammFee;
        uint256 gasFee;
        uint256 amountOut;
        uint256 vaultBalance;
    }

    function quote(
        uint256 _fromChain,
        uint256 _toChain,
        address _bridgeInToken,
        address _bridgeOutToken,
        uint256 _bridgeAmount,
        bool _withCall,
        bytes calldata _affiliateFee
    ) external view returns (QuoteResult memory result) {
        if(_fromChain == _toChain || _bridgeAmount == 0) return result;
        // affiliateFee
        if(_affiliateFee.length > 0) {
            IAffiliateFeeManager afm = IAffiliateFeeManager(registry.getContractAddress(ContractType.AFFILIATE));
            result.affiliateFee = afm.getAffiliatesFee(_bridgeAmount, _affiliateFee);
        }
        // protocolFee
        (, result.protocolFee) = registry.getProtocolFee(_bridgeInToken, _bridgeAmount);

        if(result.affiliateFee >= _bridgeAmount) return result;
        _bridgeAmount -= result.affiliateFee;
        if (result.protocolFee >= _bridgeAmount) return result;
        _bridgeAmount -= result.protocolFee;

        // VaultFee & balanceFee
        IVaultManager vm = _getVaultManager();
        (, uint32 fromVault, uint32 toVault) = vm.getVaultFeeRate();
        if(_bridgeInToken == _bridgeOutToken) {
            // balanceFee
            {
                (bool incentive, uint256 fee) = vm.getBalanceFee(_fromChain, _toChain, _bridgeInToken, _bridgeAmount);
                if(incentive) {
                    result.inTokenBalanceFee = -int256(fee);
                    _bridgeAmount += fee;
                } else {
                    // vaultFee -> will not collect vault fee when rebalance incentive
                    result.fromVaultFee = _getFee(_bridgeAmount, (fromVault + toVault));
                    result.inTokenBalanceFee = int256(fee);
                    if(fee >= _bridgeAmount) return result;
                    _bridgeAmount = _bridgeAmount - fee;
                    if(result.fromVaultFee >= _bridgeAmount) return result;
                    _bridgeAmount = _bridgeAmount - result.fromVaultFee;
                }
            }
            // gasFee
            if(_toChain != selfChainId) {
                GasInfo memory gasInfo = registry.getNetworkFeeInfoWithToken(_bridgeInToken, _toChain, _withCall);
                result.gasFee = gasInfo.estimateGas;

                // amountOut
                if(gasInfo.estimateGas > _bridgeAmount) {
                    result.amountOut = 0;
                } else {
                    result.amountOut = _bridgeAmount - gasInfo.estimateGas;
                }
            } else {
                result.amountOut = _bridgeAmount;
            }
            result.vaultBalance = _getVaultBalance(vm, _toChain, _bridgeInToken);
            if(result.vaultBalance < result.amountOut) result.amountOut = 0;
            return result;
        } else {
            // inTokenBalanceFee
            {
                (bool incentive, uint256 fee) = vm.getBalanceFee(_fromChain, selfChainId, _bridgeInToken, _bridgeAmount);
                if(incentive) {
                    result.inTokenBalanceFee = -int256(fee);
                    _bridgeAmount += fee;
                } else {
                    // fromVaultFee -> will not collect vault fee when rebalance incentive
                    result.fromVaultFee = _getFee(_bridgeAmount, fromVault);
                    result.inTokenBalanceFee = int256(fee);
                    if(fee >= _bridgeAmount) return result;
                    _bridgeAmount = _bridgeAmount - fee;
                    if(result.fromVaultFee >= _bridgeAmount) return result;
                    _bridgeAmount = _bridgeAmount - result.fromVaultFee;
                }
            }

            _bridgeAmount = registry.getAmountOut(_bridgeInToken, _bridgeOutToken, _bridgeAmount);
            
            // outTokenBalanceFee
            {
                (bool incentive, uint256 fee) = vm.getBalanceFee(selfChainId, _toChain, _bridgeOutToken, _bridgeAmount);
                    if(incentive) {
                    result.outTokenBalanceFee = -int256(fee);
                    _bridgeAmount += fee;
                } else {
                    // toVaultFee -> will not collect vault fee when rebalance incentive
                    result.toVaultFee = _getFee(_bridgeAmount, toVault);
                    result.outTokenBalanceFee = int256(fee);
                    if(fee >= _bridgeAmount) return result;
                    _bridgeAmount = _bridgeAmount - fee;
                    if(result.toVaultFee >= _bridgeAmount) return result;
                    _bridgeAmount = _bridgeAmount - result.toVaultFee;
                }
            }
            // gasFee
            if(_toChain != selfChainId) {
                GasInfo memory gasInfo = registry.getNetworkFeeInfoWithToken(_bridgeOutToken, _toChain, _withCall);
                result.gasFee = gasInfo.estimateGas;
                // amountOut
                if(gasInfo.estimateGas > _bridgeAmount) {
                    result.amountOut = 0;
                } else {
                    result.amountOut = _bridgeAmount - gasInfo.estimateGas;
                }
            } else {
                result.amountOut = _bridgeAmount;
            }
            result.vaultBalance = _getVaultBalance(vm, _toChain, _bridgeOutToken);
            if(result.vaultBalance < result.amountOut) result.amountOut = 0;
            return result;
        }

    }

    function _getVaultBalance(IVaultManager vm, uint256 chain, address token) internal view returns (uint256 balance) {
        if(chain == selfChainId) {
             // minted token has infinite balance
             address relayAddress = registry.getContractAddress(ContractType.RELAY);
            if(IMintAbleChecker(relayAddress).isMintable(token)) {
                return type(uint256).max;
            } else {
                return IERC20(token).balanceOf(relayAddress);
            }
        }
        bytes memory active = vm.getActiveVault();
        bytes memory retiring = vm.getRetiringVault();
        (int256 bal, ) = vm.getVaultTokenBalance(active, chain, token);
        // unsupported minted token on other chain
        if(bal < 0) {
            balance = 0;
        } else {
            balance = uint256(bal);
        }
        if(retiring.length > 0) {
            (int256 balRetir, ) = vm.getVaultTokenBalance(retiring, chain, token);
            if(balRetir > 0 && uint256(balRetir) > balance) {
                balance = uint256(balRetir);
            }
        }
    }

    function _getFee(uint256 amount, uint256 feeRate) internal pure returns (uint256 fee) {
        if (feeRate == 0) {
            return 0;
        }
        fee = amount * feeRate / MAX_RATE_UNIT;
    }

    function _getMembers(bytes calldata pubkey) internal view returns(address[] memory) {
        return _getTSSManager().getMembers(pubkey);
    }

    function _adjustDecimals(uint256 amount, uint256 decimals) internal pure returns(uint256) {
        return amount * 10 ** decimals / (10 ** 18);
    }

    function _adjustDecimalsInt256(int256 amount, uint256 decimals) internal pure returns(int256) {
        return amount * int256(10 ** decimals) / (10 ** 18);
    }

    function _getRelay() internal view returns (IRelay relay) {
        relay = IRelay(registry.getContractAddress(ContractType.RELAY));
    }

    function _getGasService() internal view returns (IGasService gasService) {
        gasService = IGasService(registry.getContractAddress(ContractType.GAS_SERVICE));
    }

    function _getVaultManager() internal view returns (IVaultManager vaultManager) {
        vaultManager = IVaultManager(registry.getContractAddress(ContractType.VAULT_MANAGER));
    }

    function _getTSSManager() internal view returns (ITSSManager TSSManager) {
        TSSManager = ITSSManager(registry.getContractAddress(ContractType.TSS_MANAGER));
    }
}
