// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library Errs {
    error no_access();
    error order_executed();
    error invalid_vault_token();
    error vault_token_not_registered();
    error transfer_token_out_failed();
    error transfer_token_in_failed();

    error invalid_vault();
    error invalid_signature();
    error token_allowance_not_zero();
    error migration_not_completed();
    error not_bridge_able();
    error zero_amount_out();
}
