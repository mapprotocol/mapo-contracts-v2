// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

enum ChainType {
    CONTRACT,
    UTXO,
    ACCOUNT
}

enum TxType {
    DEPOSIT,
    TRANSFER,
    MIGRATE,
    REFUND, //
    MESSAGE // todo

}

struct TxItem {
    uint256 chain;
    bytes32 orderId;
    address token;
    uint256 amount;
    uint256 transactionRate;
    uint256 transactionSize;
    bytes vault;
    bytes from;
    bytes to;
    bytes payload;
}

struct TxInItem {
    TxType txInType;
    bytes32 orderId;
    uint256 chainAndGasLimit;
    uint128 height;
    bytes token;
    uint256 amount;
    bytes from;
    bytes vault;
    bytes to;
    bytes payload;
}

struct TxOutItem {
    TxType txOutType;
    bytes32 orderId;
    uint256 chainAndGasLimit;
    uint128 height;
    uint128 gasUsed;
    uint256 sequence;
    uint256 amount;
    address sender;
    bytes token;
    bytes from;
    bytes to;
    bytes vault;
    bytes data;
}
