// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {BaseImplementation} from "@mapprotocol/common-contracts/contracts/base/BaseImplementation.sol";


interface ITssQuoter {
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
    ) external view returns (QuoteResult memory result);
}

interface IButterQuoter {
    function quote(
        bytes memory _caller,
        uint256 _fromChain,
        uint256 _toChain,
        address _bridgeInToken,
        address _bridgeOutToken,
        uint256 _bridgeAmount,
        bool _exactIn,
        bool _withSwap,
        bytes calldata _affiliateFee
    ) external view
        returns (
            uint256 bridgeInFee,
            uint256 bridgeOutFee,
            uint256 _bridgeOutOrInAmount,
            uint256 vaultBalance,
            uint256 affiliateFee
        );
}

contract FusionQuoter is BaseImplementation {
    uint256 public immutable selfChainId = block.chainid;
    uint256 public immutable btcChainId = 1360095883558913;
    
    address public fusionReceiver;
    ITssQuoter public tssQuoter;
    IButterQuoter public butterQuoter;

    struct FusionQuoterResult {
        uint256 bridgeInFee;
        uint256 bridgeOutFee;
        uint256 amountOut;
        uint256 affiliateFee;
        uint256 vaultBalance;
    }
    event Set(address _fusionReceiver, address _tssQuoter, address _butterQuoter);

    function initialize(address _defaultAdmin) public initializer {
        __BaseImplementation_init(_defaultAdmin);
    }
    function set(address _fusionReceiver, address _tssQuoter, address _butterQuoter) external restricted {
        fusionReceiver = _fusionReceiver;
        tssQuoter = ITssQuoter(_tssQuoter);
        butterQuoter = IButterQuoter(_butterQuoter);
        emit Set(_fusionReceiver, _tssQuoter, _butterQuoter);
    }

    function quote(
        uint256 _fromChain,
        uint256 _toChain,
        address _bridgeInToken,
        address _bridgeOutToken,
        uint256 _bridgeAmount,
        // bool _withSwap,
        bytes calldata _affiliateFee
    ) external view returns(FusionQuoterResult memory fusionQuoterResult) {
        require(_fromChain != selfChainId && _toChain != selfChainId);
        require(_fromChain == btcChainId || _toChain == btcChainId);
        // btc -> evm  swap on tss 
        if(_fromChain == btcChainId) {
            // affiliateFee and maybe swap
            ITssQuoter.QuoteResult memory result = tssQuoter.quote(_fromChain, selfChainId, _bridgeInToken, _bridgeOutToken, _bridgeAmount, false, _affiliateFee);
            fusionQuoterResult.affiliateFee = result.affiliateFee;
            fusionQuoterResult.bridgeInFee = result.protocolFee + result.fromVaultFee;
            if(result.inTokenBalanceFee > 0) {
                fusionQuoterResult.bridgeInFee += uint256(result.inTokenBalanceFee);
            } else {
                fusionQuoterResult.bridgeInFee -= uint256(-result.inTokenBalanceFee);
            }
            fusionQuoterResult.bridgeOutFee += result.toVaultFee;
            fusionQuoterResult.bridgeOutFee += result.gasFee;
            if(result.outTokenBalanceFee > 0) {
                fusionQuoterResult.bridgeOutFee += uint256(result.outTokenBalanceFee);
            } else {
                fusionQuoterResult.bridgeOutFee -= uint256(-result.outTokenBalanceFee);
            }
            uint256 inFee;
            uint256 outFee;
            // no affiliateFee no swap
            (
                inFee,
                outFee,
                fusionQuoterResult.amountOut,
                fusionQuoterResult.vaultBalance, 
            ) = butterQuoter.quote(abi.encodePacked(fusionReceiver), selfChainId, _toChain, _bridgeOutToken, _bridgeOutToken, result.amountOut, true, false, bytes(""));
            fusionQuoterResult.bridgeOutFee += inFee;
            fusionQuoterResult.bridgeOutFee += outFee;
        } else {
            // evm -> btc swap on mos
            (
                fusionQuoterResult.bridgeInFee,
                fusionQuoterResult.bridgeOutFee,
                fusionQuoterResult.amountOut,
                , 
                fusionQuoterResult.affiliateFee
            )  = butterQuoter.quote(abi.encodePacked(fusionReceiver), _fromChain, selfChainId, _bridgeInToken, _bridgeOutToken, _bridgeAmount, true, false, _affiliateFee);
            // no affiliateFee no swap
            ITssQuoter.QuoteResult memory result = tssQuoter.quote(selfChainId, _toChain, _bridgeOutToken, _bridgeOutToken, fusionQuoterResult.amountOut, false, bytes(""));
            fusionQuoterResult.bridgeOutFee += result.protocolFee;
            fusionQuoterResult.bridgeOutFee += result.fromVaultFee;
            fusionQuoterResult.bridgeOutFee += result.gasFee;
            fusionQuoterResult.bridgeOutFee += result.toVaultFee;
            if(result.inTokenBalanceFee > 0) {
                fusionQuoterResult.bridgeOutFee += uint256(result.inTokenBalanceFee);
            } else {
                fusionQuoterResult.bridgeOutFee -= uint256(-result.inTokenBalanceFee);
            }
            if(result.outTokenBalanceFee > 0) {
                fusionQuoterResult.bridgeOutFee += uint256(result.outTokenBalanceFee);
            } else {
                fusionQuoterResult.bridgeOutFee -= uint256(-result.outTokenBalanceFee);
            }
            fusionQuoterResult.vaultBalance = result.vaultBalance;
            fusionQuoterResult.amountOut = result.amountOut;
        }
        
    }

}
