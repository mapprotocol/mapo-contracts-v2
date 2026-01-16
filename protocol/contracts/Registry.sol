// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Utils} from "./libs/Utils.sol";
import {Errs} from "./libs/Errors.sol";
import {ISwap} from "./interfaces/swap/ISwap.sol";
import {IGasService} from "./interfaces/IGasService.sol";
import {IProtocolFee} from "./interfaces/periphery/IProtocolFee.sol";
import {IRegistry, ChainType, ContractType, GasInfo } from "./interfaces/IRegistry.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {BaseImplementation} from "@mapprotocol/common-contracts/contracts/base/BaseImplementation.sol";

contract Registry is BaseImplementation, IRegistry {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.BytesSet;

    // uint256 constant MAX_RATE_UNIT = 1_000_000;         // unit is 0.01 bps
    uint256 public immutable selfChainId = block.chainid;

    struct TokenInfo {
        bool registered;
        uint8 decimals;
        bool mintable;
        uint256 chainId;
        bytes token;
    }

    struct Token {
        uint96 id;
        address tokenAddress;
        // chain_id => decimals
        mapping(uint256 => uint8) decimals;
        // chain_id => token
        mapping(uint256 => bytes) mappingList;
    }

    struct ChainInfo {
        bool registered;
        ChainType chainType;
        address gasToken;           // the chain native token address mapped on relay chain
        address baseFeeToken;       // the base fee token address mapped on relay chain
                                    // by default, it will be the chain native token address on relay chain
                                    // like BTC for Bitcoin, ETH for Ethereum, Base, etc.
                                    // but the protocol might not support the chain native token bridge, like Kaia, it will be USDT.
                                    // it will be used when not specify bridge token, such as migration
        bytes router;
        string name;
        EnumerableSet.BytesSet tokens;
    }

    EnumerableSet.UintSet private chainList;
    mapping(ContractType => address) public addresses;

    mapping(string => uint256) private nameToChainId;
    mapping(uint256 => ChainInfo) private chainInfos;

    // hash(chainId, tokenAddress)
    mapping(bytes32 tokenId => TokenInfo) private tokenInfos;

    // Source chain to Relay chain address
    // [chain_id => [source_token => map_token]]
    mapping(uint256 => mapping(bytes => address)) public tokenMappingList;

    mapping(address => Token) public tokenList;

    mapping(uint256 => address) public mapTokenIdToAddress;

    mapping(uint256 => mapping(bytes => string)) public tokenAddressToNickname;

    mapping(uint256 => mapping(string => bytes)) public tokenNicknameToAddress;

    event RegisterContract(ContractType contractAddress, address _addr);

    event RegisterChain(uint256 _chain, ChainType _chainType, bytes _router, string _chainName, address _gasToken);
    event DeregisterChain(uint256 chain);

    event RegisterToken(uint96 indexed id, address indexed _token);

    event MapToken(address indexed _token, uint256 indexed _fromChain, bytes _fromToken, uint8 _decimals);
    event UnmapToken(uint256 indexed _fromChain, bytes _fromToken);

    event SetTokenTicker(uint256 _chain, bytes _token, string _nickname);


    modifier checkAddress(address _address) {
        if(_address == address(0)) revert Errs.zero_address();
        _;
    }

    function initialize(address _defaultAdmin) public initializer {
        __BaseImplementation_init(_defaultAdmin);
    }

    function registerContract(ContractType _contractType, address _addr) external restricted checkAddress(_addr) {
        addresses[_contractType] = _addr;
        emit RegisterContract(_contractType, _addr);
    }

    function registerChain(
        uint256 _chain,
        ChainType _chainType,
        bytes memory _router,
        address _gasToken,
        address _baseToken,
        string memory _chainName
    ) external restricted {
        ChainInfo storage chainInfo = chainInfos[_chain];

        // string memory oldName = chainInfo.name[_chain];
        delete nameToChainId[chainInfo.name];

        chainInfo.registered = true;
        chainInfo.router = _router;

        // check gasToken and baseToken
        if (_chainType != ChainType.CONTRACT) {
            require(_gasToken == _baseToken);
        }
        chainInfo.gasToken = _gasToken;
        chainInfo.baseFeeToken = _baseToken;

        chainInfo.name = _chainName;
        chainInfo.chainType = _chainType;

        nameToChainId[_chainName] = _chain;
        chainList.add(_chain);

        emit RegisterChain(_chain, _chainType, _router, _chainName, _gasToken);
    }

    function deregisterChain(uint256 _chain) external restricted {
        ChainInfo storage chainInfo = chainInfos[_chain];
        if (!chainInfo.registered) revert Errs.chain_not_registered();

        require(chainInfo.tokens.length() == 0);

        delete nameToChainId[chainInfo.name];
        delete chainInfos[_chain];
        chainList.remove(_chain);
        emit DeregisterChain(_chain);
    }

    function registerToken(uint96 _id, address _token)
        external
        restricted
        checkAddress(_token)
    {
        Token storage token = tokenList[_token];
        uint256 chainId = selfChainId;
        token.id = _id;
        token.tokenAddress = _token;
        mapTokenIdToAddress[_id] = _token;
        bytes memory tokenBytes = Utils.toBytes(_token);
        token.mappingList[chainId] = tokenBytes;
        token.decimals[chainId] = IERC20Metadata(_token).decimals();
        emit RegisterToken(_id, _token);
    }

    function mapToken(address _token, uint256 _fromChain, bytes memory _fromToken, uint8 _decimals)
        external
        restricted
        checkAddress(_token)
    {
        if (Utils.bytesEq(_fromToken, bytes(""))) revert Errs.invalid_token();
        if(_fromChain == selfChainId) revert Errs.map_token_relay_chain();
        if (!chainList.contains(_fromChain)) revert Errs.chain_not_registered();

        Token storage token = tokenList[_token];
        if (token.tokenAddress == address(0)) revert Errs.relay_token_not_registered();

        token.decimals[_fromChain] = _decimals;
        token.mappingList[_fromChain] = _fromToken;
        tokenMappingList[_fromChain][_fromToken] = _token;

        ChainInfo storage chainInfo = chainInfos[_fromChain];
        chainInfo.tokens.add(_fromToken);
        emit MapToken(_token, _fromChain, _fromToken, _decimals);
    }

    function unmapToken(uint256 _fromChain, bytes memory _fromToken) external restricted {
        if (_fromChain == selfChainId) revert Errs.map_token_relay_chain();
        address relayToken = tokenMappingList[_fromChain][_fromToken];
        if (relayToken != address(0)) revert Errs.relay_token_not_registered();

        Token storage token = tokenList[relayToken];
        if (token.tokenAddress != address(0)) {
            if (Utils.bytesEq(_fromToken, token.mappingList[_fromChain])) {
                delete token.decimals[_fromChain];
                delete token.mappingList[_fromChain];
                ChainInfo storage chainInfo = chainInfos[_fromChain];
                chainInfo.tokens.remove(_fromToken);
            }
        }
        delete tokenMappingList[_fromChain][_fromToken];

        emit UnmapToken(_fromChain, _fromToken);
    }

    function setTokenTicker(uint256 _chain, bytes memory _token, string memory _nickname) external restricted {
        string memory oldNickname = tokenAddressToNickname[_chain][_token];
        delete tokenNicknameToAddress[_chain][oldNickname];
        tokenAddressToNickname[_chain][_token] = _nickname;
        tokenNicknameToAddress[_chain][_nickname] = _token;

        emit SetTokenTicker(_chain, _token, _nickname);
    }

    function getContractAddress(ContractType _contractType) external view override returns(address) {
        return addresses[_contractType];
    }

    function getTokenAddressById(uint96 id) external view override returns (address token) {
        token = mapTokenIdToAddress[id];
    }

    function getToChainToken(address _token, uint256 _toChain)
        external
        view
        override
        returns (bytes memory _toChainToken)
    {
        return _getToChainToken(_token, _toChain);
    }

    function getToChainAmount(address _token, uint256 _amount, uint256 _toChain)
        external
        view
        override
        returns (uint256)
    {
        return _getTargetAmount(_token, selfChainId, _toChain, _amount);
    }

    function getRelayChainToken(uint256 _fromChain, bytes memory _fromToken)
        external
        view
        override
        returns (address token)
    {
        return _getRelayChainToken(_fromChain, _fromToken);
    }

    function getRelayChainAmount(bytes memory _fromToken, uint256 _fromChain, uint256 _amount)
        external
        view
        override
        returns (uint256)
    {
        address _token = _getRelayChainToken(_fromChain, _fromToken);
        return _getTargetAmount(_token, _fromChain, selfChainId, _amount);
    }

    function getRelayChainGasAmount(uint256 chain, uint256 gasAmount) external view override returns (uint256 relayGasAmount) {
        address relayGasToken = chainInfos[chain].gasToken;
        // get relay chain amount
        return _getTargetAmount(relayGasToken, chain, selfChainId, gasAmount);
    }

    function getTargetToken(uint256 _fromChain, uint256 _toChain, bytes memory _fromToken)
        external
        view
        returns (bytes memory toToken, uint8 decimals)
    {
        address tokenAddr = _getRelayChainToken(_fromChain, _fromToken);
        (toToken, decimals) = _getTargetToken(_toChain, tokenAddr);
    }

    function getTokenInfo(address _relayToken, uint256 _fromChain)
    external
    view
    override
    returns (bytes memory token, uint8 decimals, bool mintable)
    {
        token = _getToChainToken(_relayToken, _fromChain);
        if(token.length > 0) {
            TokenInfo storage info = tokenInfos[_getTokenId(_fromChain, token)];
            decimals = info.decimals;
            mintable = info.mintable;
        }
    }

    function _getTargetToken(uint256 _toChain, address _relayToken)
        private
        view
        returns (bytes memory toToken, uint8 decimals)
    {
        Token storage token = tokenList[_relayToken];
        toToken = token.mappingList[_toChain];
        decimals = token.decimals[_toChain];
    }

    function getTargetAmount(uint256 _fromChain, uint256 _toChain, bytes memory _fromToken, uint256 _amount)
        external
        view
        returns (uint256 toAmount)
    {
        address tokenAddr = _getRelayChainToken(_fromChain, _fromToken);

        toAmount = _getTargetAmount(tokenAddr, _fromChain, _toChain, _amount);
    }

    function getChains() external view override returns (uint256[] memory) {
        return chainList.values();
    }

    function getChainTokens(uint256 chain) external view override returns (bytes[] memory) {
        return chainInfos[chain].tokens.values();
    }

    function getChainRouters(uint256 chain) external view override returns (bytes memory) {
        return chainInfos[chain].router;
    }

    function getChainType(uint256 chain) external view override returns (ChainType) {
        return chainInfos[chain].chainType;
    }

    function getChainGasToken(uint256 chain) external view override returns (address) {
        return chainInfos[chain].gasToken;
    }

    function getChainBaseToken(uint256 chain) external view override returns (address) {
        return chainInfos[chain].baseFeeToken;
    }

    function isRegistered(uint256 chain) external view override returns (bool) {
        return chainInfos[chain].registered;
    }

    function getTokenDecimals(uint256 chain, bytes calldata token) external view override returns (uint256) {
        address relayToken;
        if(chain == selfChainId) {
            relayToken = Utils.fromBytes(token);
        } else {
            relayToken = tokenMappingList[chain][token];
        }
        Token storage t = tokenList[relayToken];
        return t.decimals[chain];
    }

    function getChainName(uint256 chain) external view override returns (string memory) {
        return chainInfos[chain].name;
    }

    function getChainByName(string memory name) external view override returns (uint256) {
        return nameToChainId[name];
    }

    function getTokenNickname(uint256 chain, bytes memory token) external view override returns (string memory) {
        return tokenAddressToNickname[chain][token];
    }

    function getTokenAddressByNickname(uint256 chain, string memory nickname)
        external
        view
        override
        returns (bytes memory)
    {
        return tokenNicknameToAddress[chain][nickname];
    }

    function getProtocolFee(address token, uint256 amount) external view override returns (address, uint256) {
        address feeManager = addresses[ContractType.PROTOCOL_FEE];
        uint256 fee = IProtocolFee(feeManager).getProtocolFee(token, amount);

        return (feeManager, fee);
    }

    function getAmountOut(address tokenIn, address tokenOut, uint256 amountIn) external view override returns (uint256) {
        return _getAmountOut(tokenIn, tokenOut, amountIn);
    }

    function getMigrateGasFee(uint256 chain, address feePaidToken, uint256 estimateGas) external view override returns (uint256 amount) {
        ChainInfo storage info  = chainInfos[chain];
        amount = estimateGas;
        if(info.gasToken != feePaidToken) {
            amount = _getAmountOut(info.gasToken, feePaidToken, estimateGas);
        }
    }

    function getNetworkFeeInfoWithToken(address token, uint256 chain, bool withCall)
    external
    view
    override
    returns (GasInfo memory)
    {
        return _getNetworkFeeInfo(token, chain, withCall);
    }

    function getNetworkFeeInfo(uint256 chain, bool withCall)
    external
    view
    override
    returns (GasInfo memory)
    {
        address token = chainInfos[chain].baseFeeToken;

        return _getNetworkFeeInfo(token, chain, withCall);
    }

    function _getAmountOut(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        return ISwap(addresses[ContractType.SWAP]).getAmountOut(tokenIn, tokenOut, amountIn);
    }

    function _getRelayChainToken(uint256 _fromChain, bytes memory _fromToken) internal view returns (address token) {
        if (_fromChain == selfChainId) {
            token = Utils.fromBytes(_fromToken);
        } else {
            token = tokenMappingList[_fromChain][_fromToken];
        }
    }

    function _getNetworkFeeInfo(address token, uint256 chain, bool withCall)
    internal
    view
    returns (GasInfo memory)
    {
        (uint256 networkFee, uint256 transactionRate, uint256 transactionSize) = IGasService(addresses[ContractType.GAS_SERVICE]).getNetworkFeeInfo(chain, withCall);

        address relayGasToken = chainInfos[chain].gasToken;
        // get relay chain amount
        uint256 relayNetworkFee = _getTargetAmount(relayGasToken, chain, selfChainId, networkFee);
        if(relayNetworkFee == 0) revert Errs.relay_token_not_registered();

        if (relayGasToken != token) {
            relayNetworkFee = _getAmountOut(relayGasToken, token, relayNetworkFee);
        }

        return GasInfo(token, uint128(_truncation(relayNetworkFee)), transactionRate, transactionSize);
    }

    function _truncation(uint256 amount) internal pure returns(uint256) {
        uint256 ad = _adjustDecimals(amount, 6, 18);
        ad = (ad == 0) ? 1 : ad;  
        return _adjustDecimals(ad, 18, 6);
    }

    function _adjustDecimals(uint256 amount, uint256 decimalsMul, uint256 decimalsDiv) internal pure returns(uint256) {
        return amount * 10 ** decimalsMul / (10 ** decimalsDiv);
    }

    function _getToChainToken(address _token, uint256 _toChain) internal view returns (bytes memory token) {
        if (_toChain == selfChainId) {
            token = Utils.toBytes(_token);
        } else {
            token = tokenList[_token].mappingList[_toChain];
        }
    }

    function _getTargetAmount(address _token, uint256 _fromChain, uint256 _toChain, uint256 _amount)
        internal
        view
        returns (uint256)
    {
        if (_toChain == _fromChain) {
            return _amount;
        }
        Token storage token = tokenList[_token];
        if(token.tokenAddress != address(0)) {
            uint256 decimalsFrom = token.decimals[_fromChain];
            uint256 decimalsTo = token.decimals[_toChain];
            if(decimalsFrom > 0 && decimalsTo > 0) {
                return (_amount * (10 ** decimalsTo)) / (10 ** decimalsFrom);
            }
        }
        return 0;
    }

    function _getTokenId(uint256 _chain, bytes memory _token) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(_chain, _token));
    }
}
