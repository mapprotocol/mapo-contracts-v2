// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IVaultToken} from "./interfaces/IVaultToken.sol";

contract VaultToken is IVaultToken, AccessControlEnumerable, ERC20Burnable {
    using SafeCast for uint256;

    using EnumerableSet for EnumerableSet.UintSet;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    uint8 private _decimals;
    address private underlying;
    uint256 public totalVault;

    // chain_id => vault_value
    mapping(uint256 => int256) private vaultBalance;
    EnumerableSet.UintSet private _chainSet;

    error underlying_address_is_zero();
    error only_manager_role();

    event DepositVault(address indexed token, address indexed to, uint256 vaultValue, uint256 value);
    event WithdrawVault(address indexed token, address indexed to, uint256 vaultValue, uint256 value);

    event UpdateVault(address indexed token, uint256 fromChain, uint256 toChain, uint256);

    /**
     * @dev Grants `DEFAULT_ADMIN_ROLE`, `MANAGER_ROLE` to the
     * account that deploys the contract.
     *
     * See {ERC20-constructor}.
     */
    constructor(address _underlying, string memory _name, string memory _symbol) ERC20(_name, _symbol) {
        if (_underlying == address(0)) revert underlying_address_is_zero();
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        _grantRole(MANAGER_ROLE, _msgSender());

        underlying = _underlying;

        _decimals = IERC20Metadata(underlying).decimals();
    }

    function addManager(address _manager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MANAGER_ROLE, _manager);
    }

    function removeManager(address _manager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(MANAGER_ROLE, _manager);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function getVaultByChainId(uint256 _chain) external view override returns (int256) {
        return vaultBalance[_chain];
    }

    function getVaultByIndex(uint256 index) external view returns (int256) {
        uint256 chain = _chainSet.at(index);

        return vaultBalance[chain];
    }

    function allChains() external view override returns (uint256[] memory) {
        return _chainSet.values();
    }

    function getChain(uint256 index) external view returns (uint256) {
        return _chainSet.at(index);
    }

    function chainCount() external view virtual returns (uint256) {
        return _chainSet.length();
    }

    function getVaultTokenAmount(uint256 _amount) public view returns (uint256) {
        if (totalSupply() == 0) {
            return _amount;
        }
        uint256 allVToken = totalSupply();
        return (_amount * allVToken) / totalVault;
    }

    function getTokenAmount(uint256 _amount) public view override returns (uint256) {
        uint256 allVToken = totalSupply();
        if (allVToken == 0) {
            return _amount;
        }
        return (_amount * totalVault) / allVToken;
    }

    function getTokenAddress() external view override returns (address) {
        return underlying;
    }

    function deposit(uint256 _fromChain, uint256 _amount, address _to) external override onlyRole(MANAGER_ROLE) {
        uint256 amount = getVaultTokenAmount(_amount);
        _mint(_to, amount);

        vaultBalance[_fromChain] += _amount.toInt256();
        _chainSet.add(_fromChain);

        totalVault += _amount;

        emit DepositVault(underlying, _to, _amount, amount);
    }

    function withdraw(uint256 _toChain, uint256 _vaultAmount, address _to) external override onlyRole(MANAGER_ROLE) {
        uint256 amount = getTokenAmount(_vaultAmount);
        _burn(_to, _vaultAmount);

        vaultBalance[_toChain] -= amount.toInt256();
        _chainSet.add(_toChain);

        totalVault -= amount;

        emit WithdrawVault(underlying, _to, _vaultAmount, amount);
    }

    function transferToken(
        uint256 _fromChain,
        uint256 _amount,
        uint256 _toChain,
        uint256 _outAmount,
        uint256 _relayChain,
        uint256 _fee
    ) external override onlyRole(MANAGER_ROLE) {
        vaultBalance[_fromChain] += _amount.toInt256();
        vaultBalance[_toChain] -= _outAmount.toInt256();

        uint256 vaultFee = _amount - _outAmount - _fee;
        totalVault += vaultFee;

        _chainSet.add(_fromChain);
        _chainSet.add(_toChain);
        _chainSet.add(_relayChain);
    }

    function updateVault(
        uint256 _fromChain,
        uint256 _amount,
        uint256 _toChain,
        uint256 _outAmount,
        uint256 _relayChain,
        uint256 _vaultFee
    ) external override onlyRole(MANAGER_ROLE) {
        vaultBalance[_fromChain] += _amount.toInt256();
        vaultBalance[_toChain] -= _outAmount.toInt256();

        totalVault += _vaultFee;

        _chainSet.add(_fromChain);
        _chainSet.add(_toChain);
        _chainSet.add(_relayChain);

        // todo
        // emit UpdateVault();
    }

    function increaseVaultBalance(uint256 chain, uint256 amount) external override onlyRole(MANAGER_ROLE) {
        vaultBalance[chain] += amount.toInt256();
    }

    function reduceVaultBalance(uint256 chain, uint256 amount) external override onlyRole(MANAGER_ROLE) {
            vaultBalance[chain] -= amount.toInt256();
    }

}
