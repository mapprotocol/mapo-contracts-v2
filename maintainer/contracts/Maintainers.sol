// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Utils} from "./libs/Utils.sol";
import {IParameters} from "./interfaces/IParameters.sol";
import {IMaintainers} from "./interfaces/IMaintainers.sol";
import {IValidators} from "./interfaces/IValidators.sol";
import {IElection} from "./interfaces/IElection.sol";
import {IAccounts} from "./interfaces/IAccounts.sol";
import {ITSSManager} from "./interfaces/ITSSManager.sol";

import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {BaseImplementation} from "@mapprotocol/common-contracts/contracts/base/BaseImplementation.sol";

contract Maintainers is BaseImplementation, IMaintainers {
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    address public constant ACCOUNTS_ADDRESS = 0x000000000000000000000000000000000000d010;
    address public constant VALIDATORS_ADDRESS = 0x000000000000000000000000000000000000D012;
    address public constant ELECTIONS_ADDRESS = 0x000000000000000000000000000000000000d013;
    string public constant version = "1.0.0";

    bytes32 private constant REWARD_PER_BLOCK = keccak256(bytes("REWARD_PER_BLOCK"));
    bytes32 private constant BLOCKS_PER_EPOCH = keccak256(bytes("BLOCKS_PER_EPOCH"));
    bytes32 private constant MAX_BLOCKS_FOR_UPDATE_TSS = keccak256("MAX_BLOCKS_FOR_UPDATE_TSS");
    bytes32 private constant MAX_SLASH_POINT_FOR_ELECT = keccak256(bytes("MAX_SLASH_POINT_FOR_ELECT"));
    bytes32 private constant ADDITIONAL_REWARD_MAX_SLASH_POINT = keccak256(bytes("ADDITIONAL_REWARD_MAX_SLASH_POINT"));

    bytes32 private constant JAIL_BLOCK = keccak256(bytes("JAIL_BLOCK"));

    uint256 private constant TSS_MAX_NUMBER = 30;
    uint256 private constant TSS_MIN_NUMBER = 3;

    uint256 public rewardEpoch;
    uint256 public currentEpoch;
    uint256 public electionEpoch;

    uint256 public maintainerLimit;

    ITSSManager public tssManager;
    IParameters public parameters;

    mapping(address => MaintainerInfo) private maintainerInfos;

    mapping(uint256 => EpochInfo) private epochInfos;

    EnumerableMap.AddressToUintMap internal jailList;

    mapping(address => address) public maintainerToValidator;

    error no_access();
    error empty_pubkey();
    error invalid_pubkey();
    error empty_p2pAddress();
    error maintainer_not_enough();
    error only_validator_can_register();

    event Heartbeat(address m);
    event Deregister(address user);
    event Set(address _manager, address _parameter);
    event UpdateMaintainerLimit(uint256 limit);
    event Activate(address validator, address maintainer);
    event Revoke(address validator, address maintainer);
    event ReleaseFromJail(address m);
    event AddToJail(address m, uint256 jailBlock);
    event DistributeReward(uint256 epoch, address m, uint256 value);
    event Elect(uint256 epochId, address[] maintainers, bool maintainersUpdate);
    event Update(address validator, address maintainerAddr, bytes secp256Pubkey, bytes ed25519PubKey, string p2pAddress);
    event Register(address validator, address maintaierAddr, bytes secp256Pubkey, bytes ed25519PubKey, string p2pAddress);

    modifier onlyVm() {
        if (msg.sender != address(0)) revert no_access();
        _;
    }

    function initialize(address _defaultAdmin) public initializer {
        __BaseImplementation_init(_defaultAdmin);
    }

    receive() external payable {}

    function set(address _manager, address _parameter) external restricted {
        require(_manager != address(0) && _parameter != address(0));
        parameters = IParameters(_parameter);
        tssManager = ITSSManager(_manager);
        emit Set(_manager, _parameter);
    }

    function updateMaintainerLimit(uint256 _limit) external restricted {
        require(_limit >= TSS_MIN_NUMBER && _limit <= TSS_MAX_NUMBER);
        maintainerLimit = _limit;
        emit UpdateMaintainerLimit(_limit);
    }

    function register(address maintainerAddr, bytes calldata secp256Pubkey, bytes calldata ed25519PubKey, string calldata p2pAddress)
        external
    {
        require(maintainerAddr != address(0));
        require(maintainerToValidator[maintainerAddr] == address(0));
        address validator = msg.sender;
        MaintainerInfo storage info = maintainerInfos[validator];
        require(info.status == MaintainerStatus.UNKNOWN);
        _checkRegisterParameters(secp256Pubkey, ed25519PubKey, p2pAddress, maintainerAddr);
        if (!_isValidator(validator)) revert only_validator_can_register();
        info.status = MaintainerStatus.REGISTERED;
        info.p2pAddress = p2pAddress;
        info.secp256Pubkey = secp256Pubkey;
        info.ed25519Pubkey = ed25519PubKey;
        info.account = maintainerAddr;
        maintainerToValidator[maintainerAddr] = validator;
        emit Register(validator, maintainerAddr, secp256Pubkey, ed25519PubKey, p2pAddress);
    }

    function deregister() external {
        address validator = msg.sender;
        MaintainerInfo storage info = maintainerInfos[validator];
        require(info.status == MaintainerStatus.REGISTERED);
        require(info.lastActiveEpoch == 0 || (info.lastActiveEpoch + 1) < currentEpoch);
        delete maintainerToValidator[info.account];
        delete maintainerInfos[validator];

        emit Deregister(validator);
    }

    function activate() external {
        address maintainerAddr = msg.sender;
        address validator = maintainerToValidator[maintainerAddr];
        MaintainerInfo storage info = maintainerInfos[validator];
        require(info.status == MaintainerStatus.REGISTERED);
        info.status = MaintainerStatus.STANDBY;
        emit Activate(validator, maintainerAddr);
    }


    function revoke() external {
        address maintainerAddr = msg.sender;
        address validator = maintainerToValidator[maintainerAddr];
        MaintainerInfo storage info = maintainerInfos[validator];
        require(
            info.status == MaintainerStatus.STANDBY || info.status == MaintainerStatus.READY || info.status == MaintainerStatus.ACTIVE
        );
        info.status = MaintainerStatus.REGISTERED;
        emit Revoke(validator, maintainerAddr);
    }

    function update(address maintainerAddr, bytes calldata secp256Pubkey, bytes calldata ed25519PubKey, string calldata p2pAddress) external {
        require(maintainerAddr != address(0));
        address validator = msg.sender;
        MaintainerInfo storage info = maintainerInfos[validator];
        require(info.status == MaintainerStatus.REGISTERED);
        require(info.lastActiveEpoch == 0 || info.lastActiveEpoch < currentEpoch);
        _checkRegisterParameters(secp256Pubkey, ed25519PubKey, p2pAddress, maintainerAddr);
        info.status = MaintainerStatus.STANDBY;
        info.p2pAddress = p2pAddress;
        info.secp256Pubkey = secp256Pubkey;
        info.ed25519Pubkey = ed25519PubKey;
        delete maintainerToValidator[info.account];
        info.account = maintainerAddr;
        maintainerToValidator[maintainerAddr] = validator;
        emit Update(validator, maintainerAddr, secp256Pubkey, ed25519PubKey, p2pAddress);
    }

    function heartbeat() external {
        MaintainerInfo storage info = maintainerInfos[maintainerToValidator[msg.sender]];
        require(info.status != MaintainerStatus.UNKNOWN);
        info.lastHeartbeatTime = block.timestamp;
        emit Heartbeat(msg.sender);
    }


    function getMaintainerInfos(address[] calldata ms) external view returns(MaintainerInfo[] memory infos) {
        uint256 len = ms.length;
        infos  = new MaintainerInfo[](len);
        for (uint i = 0; i < len; i++) {
            infos[i] = maintainerInfos[maintainerToValidator[ms[i]]];
        }
    }

    function getEpochInfo(uint256 epochId) external view returns(EpochInfo memory info) {
        epochId = epochId == 0 ? currentEpoch : epochId;
        info = epochInfos[epochId];
    }

    function jail(address[] calldata _maintainers) external override {
        if (msg.sender != address(tssManager)) revert no_access();
        uint256 len = _maintainers.length;
        uint256 jailBlock = block.number + _getParameter(JAIL_BLOCK);
        for (uint i = 0; i < len;) {
            address _maintainer = _maintainers[i];
            maintainerInfos[maintainerToValidator[_maintainer]].status = MaintainerStatus.JAILED;
            jailList.set(_maintainer, jailBlock);
            emit AddToJail(_maintainer, jailBlock);
            unchecked {
                ++i;
            }
        }
    }

    function _releaseFromJail() internal {
        uint256 blockNumber = block.number;
        address[] memory maintainers = jailList.keys();
        for (uint256 i = 0; i < maintainers.length; i++) {
            address m = maintainers[i];
            if (jailList.get(m) >= blockNumber) {
                continue;
            }
            jailList.remove(m);
            maintainerInfos[maintainerToValidator[m]].status = MaintainerStatus.STANDBY;
            emit ReleaseFromJail(m);
        }
    }

    function orchestrate() external {
        if (electionEpoch == 0) {
            if (_needElect(currentEpoch)) {
                _releaseFromJail();

                (address[] memory maintainers, uint256 selectedCount) = _chooseMaintainers();
                if (selectedCount < TSS_MIN_NUMBER) {
                    return;
                }
                electionEpoch = currentEpoch + 1;
                EpochInfo storage epoch = epochInfos[electionEpoch];
                _elect(epoch, maintainers);

                return;
            }
        } else {
            ITSSManager.TSSStatus status = tssManager.getTSSStatus(electionEpoch);
            EpochInfo storage epoch = epochInfos[electionEpoch];
            if (_needReElect(status, epoch)) {
                // todo: slash and re-elect maintainers
                _releaseFromJail();

                (address[] memory maintainers, uint256 selectedCount) = _chooseMaintainers();
                if (selectedCount < TSS_MIN_NUMBER) {
                    return;
                }

                if (Utils.addressListEq(maintainers, epoch.maintainers)) {
                    // no change
                    return;
                }
                _switchMaintainerStatus(epoch.maintainers, MaintainerStatus.ACTIVE, MaintainerStatus.STANDBY);

                _elect(epoch, maintainers);
                return;
            } else if (status == ITSSManager.TSSStatus.KEYGEN_COMPLETED) {
                // finish tss keygen, start migration
                tssManager.rotate(currentEpoch, electionEpoch);
                EpochInfo storage e = epochInfos[currentEpoch];
                uint64 _block = _getBlock();
                e.endBlock = _block;
                epoch.startBlock = _block;
                _updateMaintainerLastActiveEpoch(electionEpoch, epoch.maintainers);
                // switch elected maintainers status to ACTIVE
                _switchMaintainerStatus(epoch.maintainers, MaintainerStatus.ACTIVE, MaintainerStatus.ACTIVE);
                return;
            } else if (status == ITSSManager.TSSStatus.MIGRATED) {
                // migration completed
                tssManager.retire(currentEpoch, electionEpoch);
                EpochInfo storage retireEpoch = epochInfos[currentEpoch];
                currentEpoch = electionEpoch;
                electionEpoch = 0;
                retireEpoch.migratedBlock = _getBlock();
                // switch pre epoch maintainers status to STANDBY
                // keep ACTIVE if elected by current epoch
                _switchMaintainerStatus(retireEpoch.maintainers, MaintainerStatus.STANDBY, MaintainerStatus.STANDBY);
                _switchMaintainerStatus(epoch.maintainers, MaintainerStatus.ACTIVE, MaintainerStatus.ACTIVE);
                return;
            }
        }

        // other status, call migrate to schedule vault migration
        tssManager.migrate();
    }

    function _elect(EpochInfo storage epoch, address[] memory maintainers) internal {

        uint64 _block = _getBlock();
        epoch.electedBlock = _block;

        epoch.maintainers = maintainers;
        bool maintainersUpdate = tssManager.elect(electionEpoch, epoch.maintainers);
        if (!maintainersUpdate) {
            // no need rotate
            EpochInfo storage retireEpoch = epochInfos[currentEpoch];

            retireEpoch.endBlock = _block;
            retireEpoch.migratedBlock = _block;

            epoch.startBlock = _block;

            currentEpoch = electionEpoch;
            electionEpoch = 0;

            _updateMaintainerLastActiveEpoch(currentEpoch, maintainers);
        } else {
            // switch next epoch elected maintainers status to READY
            // keep current epoch elected maintainers status ACTIVE
            _switchMaintainerStatus(maintainers, MaintainerStatus.ACTIVE, MaintainerStatus.READY);
        }
        emit Elect(electionEpoch, maintainers, maintainersUpdate);
    }


    /**
     * The reward is divided into two parts:
     * one half is distributed equally among all maintainers,
     * while the other half is allocated based on each user's SLASH_POINT.
     * First, a maximum SLASH_POINT threshold is set for eligibility to receive this latter portion of the reward.
     * Users exceeding this threshold are disqualified from receiving this part of the reward.
     * The difference between this threshold and a user's SLASH_POINT (for those below the threshold) can be referred to as a "score" or "weight."
     * This portion of the reward is then distributed to all maintainers proportionally based on these scores or weights.
     */
    function distributeReward() external payable override onlyVm {
        uint256 _rewardEpoch = rewardEpoch + 1;
        EpochInfo storage e = epochInfos[_rewardEpoch];
        // Use local epoch bookkeeping instead of TSS status so rewards remain claimable
        // when the same maintainer set is re-elected and no RETIRED transition is emitted.
        if (e.migratedBlock > 0 && _rewardEpoch < currentEpoch) {
            uint256 totalReward = (e.endBlock - e.startBlock) * _getParameter(REWARD_PER_BLOCK);
            uint256[] memory points = tssManager.batchGetSlashPoint(_rewardEpoch, e.maintainers);
            uint256 arm = _getParameter(ADDITIONAL_REWARD_MAX_SLASH_POINT);
            uint256 mask = _getSlashPointMask(arm, points);
            uint256 len = points.length;

            if (mask == 0) {
                uint256 reward = totalReward / len;
                for (uint256 i = 0; i < len;) {
                    payable(e.maintainers[i]).transfer(reward);
                    emit DistributeReward(_rewardEpoch, e.maintainers[i], reward);
                    unchecked {
                        ++i;
                    }
                }
            } else {
                uint256 baseReward = totalReward / 2 / len;
                uint256 rewardPerMask = totalReward / 2 / mask;
                for (uint256 i = 0; i < len;) {
                    uint256 additionalReward = arm > points[i] ? rewardPerMask * (arm - points[i]) : 0;
                    uint256 reward = baseReward + additionalReward;
                    payable(e.maintainers[i]).transfer(reward);
                    emit DistributeReward(_rewardEpoch, e.maintainers[i], reward);
                    unchecked {
                        ++i;
                    }
                }
            }

            rewardEpoch = _rewardEpoch;
        }
    }

    function _switchMaintainerStatus(address[] memory maintainers, MaintainerStatus keep, MaintainerStatus target)
        internal
    {
        uint256 len = maintainers.length;
        for (uint256 i = 0; i < len; i++) {

            MaintainerInfo storage info = maintainerInfos[maintainerToValidator[maintainers[i]]];
            
            if(
                info.status == keep || info.status == MaintainerStatus.REVOKED || 
                info.status == MaintainerStatus.JAILED || info.status == MaintainerStatus.REGISTERED
            ) continue;

            info.status = target;
        }
    }

    function _updateMaintainerLastActiveEpoch(uint256 _epoch, address[] memory ms) internal {
        uint256 len = ms.length;
        for (uint256 i = 0; i < len;) {
            MaintainerInfo storage info = maintainerInfos[maintainerToValidator[ms[i]]];
            info.lastActiveEpoch = _epoch;
            unchecked {
                ++i;
            }
        }
    }

    function _chooseMaintainers() internal view returns (address[] memory, uint256) {
        uint256 e = currentEpoch;
        address[] memory validators = _getCurrentValidators();
        uint256 length = validators.length;
        uint256 limit = maintainerLimit;
        address[] memory maintainers = new address[](limit);
        uint256 selectedCount;
        ITSSManager m = tssManager;
        for (uint256 i = 0; i < length;) {
            MaintainerInfo storage info = maintainerInfos[validators[i]];
            // todo: check and sort by stake amount
            if (_validateCandidate(m, e, info.account, info.status)) {
                maintainers[selectedCount] = info.account;
                selectedCount++;

                if (selectedCount == limit) break;
            }
            unchecked {
                ++i;
            }
        }
        return (_subList(maintainers, selectedCount), selectedCount);
    }

    function _needElect(uint256 epochId) internal view returns (bool) {
        if(epochId == 0) return true;
        ITSSManager.TSSStatus status = tssManager.getTSSStatus(epochId);
        EpochInfo storage epoch = epochInfos[epochId];
        return (
            status == ITSSManager.TSSStatus.ACTIVE
                && (epoch.startBlock + _getParameter(BLOCKS_PER_EPOCH) < block.number)
        );
    }

    function _needReElect(ITSSManager.TSSStatus status, EpochInfo storage epoch) internal view returns (bool) {
        return status == ITSSManager.TSSStatus.KEYGEN_FAILED
            || (
                status == ITSSManager.TSSStatus.KEYGEN_CONSENSUS
                    && (epoch.electedBlock + _getParameter(MAX_BLOCKS_FOR_UPDATE_TSS) < block.number)
            );
    }

    function _validateCandidate(ITSSManager m, uint256 epochId, address maintainerAddr, MaintainerStatus status) internal view returns (bool) {
        if (status != MaintainerStatus.STANDBY && status != MaintainerStatus.ACTIVE && status != MaintainerStatus.READY) {
            return false;
        }
        // check election epoch point when reelecting
        uint256 checkEpoch = (electionEpoch == 0) ? epochId : electionEpoch;
        uint256 slashPoint = m.getSlashPoint(checkEpoch, maintainerAddr);
        if (slashPoint > _getParameter(MAX_SLASH_POINT_FOR_ELECT)) return false;

        return true;
    }

    function _checkRegisterParameters(
        bytes calldata secp256Pubkey,
        bytes calldata ed25519PubKey,
        string calldata p2pAddress,
        address maintainerAddr
    ) internal pure {
        if (secp256Pubkey.length == 0 || ed25519PubKey.length == 0) {
            revert empty_pubkey();
        }
        if (bytes(p2pAddress).length == 0) revert empty_p2pAddress();
        if(_getAddressFromPublicKey(secp256Pubkey) != maintainerAddr) revert invalid_pubkey();
    }

    function _getAddressFromPublicKey(bytes calldata publicKey) internal pure returns (address) {
        return address(uint160(uint256(keccak256(publicKey))));
    }

    function _getCurrentValidators() internal view returns (address[] memory validators) {
        IAccounts account = IAccounts(ACCOUNTS_ADDRESS);
        address[] memory signers = IElection(ELECTIONS_ADDRESS).getCurrentValidatorSigners();
        uint256 len = signers.length;
        validators = new address[](len);
        for (uint i = 0; i < len;) {
            validators[i] = account.validatorSignerToAccount(signers[i]);
            unchecked {
               ++i;
            }
        }
    }

    function _isValidator(address _user) internal view returns (bool) {
        address account = IAccounts(ACCOUNTS_ADDRESS).validatorSignerToAccount(_user);
        return IValidators(VALIDATORS_ADDRESS).isValidator(account);
    }

    function _getSlashPointMask(uint256 arm, uint256[] memory points) internal pure returns (uint256 mask) {
        uint256 len = points.length;
        for (uint256 i = 0; i < len;) {
            if (arm > points[i]) {
                mask += (arm - points[i]);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _subList(address[] memory list, uint256 count) internal pure returns(address[] memory) {
        if(count >= list.length) return list;
        address[] memory subs = new address[](count);
        for (uint i = 0; i < count;) {
            subs[i] = list[i];
            unchecked {
                ++i;
            }
        }
        return subs;
    }

    function _getBlock() internal view returns (uint64) {
        return uint64(block.number);
    }

    function _getParameter(bytes32 hash) internal view returns (uint256) {
        return parameters.getByHash(hash);
    }
}
