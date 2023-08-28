from tests.constants import PRIME_CASH_VAULT_MATURITY

def deposit(window):
    if len(window) == 1:
        # This means the lookbehind was ignored
        return (
            window[0]['transferType'] == 'Mint' and
            window[0]['assetType'] == 'pCash' and
            window[0]['toSystemAccount'] != 'Fee Reserve'
        )
    else:
        return not (
            # A deposit is not preceded by a mint of pDebt
            window[0]['transferType'] == 'Mint' and window[0]['assetType'] == 'pDebt'
        ) and (
            window[1]['transferType'] == 'Mint' and
            window[1]['assetType'] == 'pCash' and
            window[1]['toSystemAccount'] is None # System accounts have special deposit criteria
        )

def mint_pcash_fee(window):
    return (
        window[0]['transferType'] == 'Mint' and
        window[0]['assetType'] == 'pCash' and
        window[0]['toSystemAccount'] == 'Fee Reserve'
    )

def deposit_transfer(window):
    # Look for a transfer preceded by a deposit from the same address, this will
    # rewrite the window[0] bundle name
    return (
        window[0]['bundleName'] == 'Deposit'
    ) and (
        window[1]['transferType'] == 'Transfer' and
        window[1]['assetType'] == 'pCash' and
        window[0]['to'] == window[1]['from'] and
        window[0]['asset'] == window[1]['asset'] and
        # Exclude the nToken since this messes with an edge case
        window[1]['toSystemAccount'] != 'nToken'
    )

def withdraw(window):
    if len(window) == 1:
        # This means the lookbehind was ignored
        return (
            window[0]['transferType'] == 'Burn'
            and window[0]['assetType'] == 'pCash'
            # Exclude Vault Entry Transfers
            and window[0]['fromSystemAccount'] is None
        )
    else:
        return not (
            # A withdraw is not preceded by a burn of pDebt
            window[0]['transferType'] == 'Burn' and window[0]['assetType'] == 'pDebt'
        ) and (
            window[1]['transferType'] == 'Burn'
            and window[1]['assetType'] == 'pCash'
            # Exclude Vault Entry Transfers
            and window[1]['fromSystemAccount'] is None
        )

def ntoken_residual_transfer(window):
    # Any transfer of fCash on the nToken that is not preceded by a reserve fee is a residual transfers
    # (it is not a purchase of fCash)
    return not (
        window[0]['assetType'] == 'pCash'
        and window[0]['transferType'] == 'Transfer'
        and window[0]['toSystemAccount'] == 'Fee Reserve'
    ) and (
        window[1]['assetType'] == 'fCash' and
        window[1]['transferType'] == 'Transfer' and 
        (window[1]['fromSystemAccount'] == 'nToken' or window[1]['toSystemAccount'] == 'nToken')
    )

def ntoken_purchase_positive_residual(window):
    return not (
        window[0]['assetType'] == 'pCash'
        and window[0]['transferType'] == 'Transfer'
        and window[0]['toSystemAccount'] == 'Fee Reserve'
    ) and (
        window[1]['assetType'] == 'pCash' and
        window[1]['transferType'] == 'Transfer' and 
        window[1]['toSystemAccount'] == 'nToken'
    ) and (
        window[2]['assetType'] == 'fCash' and
        window[2]['transferType'] == 'Transfer' and 
        window[2]['fromSystemAccount'] == 'nToken'
    )


def ntoken_purchase_negative_residual(window):
    return not (
        window[0]['assetType'] == 'pCash'
        and window[0]['transferType'] == 'Transfer'
        and window[0]['toSystemAccount'] == 'Fee Reserve'
    ) and (
        window[1]['assetType'] == 'pCash' and
        window[1]['transferType'] == 'Transfer' and 
        window[1]['fromSystemAccount'] == 'nToken'
    ) and (
        # The account burns the positive fCash
        window[2]['assetType'] == 'fCash' and
        window[2]['transferType'] == 'Transfer' and 
        window[2]['fromSystemAccount'] == None and
        window[2]['toSystemAccount'] == 'nToken'
    ) and (
        # The nToken burns an fCash pair
        window[3]['assetType'] == 'fCash' and
        window[3]['transferType'] == 'Burn' and 
        window[3]['fromSystemAccount'] == 'nToken'
    ) and (
        window[4]['assetType'] == 'fCash' and
        window[4]['transferType'] == 'Burn' and 
        window[4]['fromSystemAccount'] == 'nToken'
    ) and (
        window[2]['value'] == window[3]['value'] and
        window[3]['value'] == -window[4]['value']
    )

def transfer_asset(window):
    return (
        window[0]['transferType'] == 'Transfer'
        and window[0]['fromSystemAccount'] is None
        and window[0]['toSystemAccount'] is None
    )

def transfer_incentive(window):
    return (
        window[0]['transferType'] == 'Transfer'
        and window[0]['assetType'] == 'NOTE'
        and window[0]['fromSystemAccount'] == 'Notional'
        and window[0]['toSystemAccount'] is None
    )

def settle_cash(window):
    # Global settlement will mint a borrow pCash pair and then will see transfers from here
    return (
        window[0]['fromSystemAccount'] == 'Settlement'
        and window[0]['transferType'] == 'Transfer'
        and window[0]['toSystemAccount'] != 'nToken'
        and (window[0]['assetType'] == 'pCash' or window[0]['assetType'] == 'pDebt')
    )

def settle_fcash(window):
    return (
        window[0]['transferType'] == 'Burn'
        and window[0]['assetType'] == 'fCash'
        and window[0]['fromSystemAccount'] != 'nToken'
        # Must be past maturity
        and window[0]['maturity'] <= window[0]['timestamp']
    )

def settle_cash_ntoken(window):
    # Global settlement will mint a borrow pCash pair and then will see transfers from here
    return (
        window[0]['fromSystemAccount'] == 'Settlement'
        and window[0]['transferType'] == 'Transfer'
        and window[0]['toSystemAccount'] == 'nToken'
        and (window[0]['assetType'] == 'pCash' or window[0]['assetType'] == 'pDebt')
    )

def settle_fcash_ntoken(window):
    return (
        window[0]['transferType'] == 'Burn'
        and window[0]['assetType'] == 'fCash'
        and window[0]['fromSystemAccount'] == 'nToken'
        # Must be past maturity
        and window[0]['maturity'] <= window[0]['timestamp']
    )

def borrow_pcash(window):
    return (
        window[0]['assetType'] == 'pDebt'
        and window[0]['transferType'] == 'Mint'
        and window[0]['toSystemAccount'] != 'Settlement'
        and window[0]['toSystemAccount'] != 'Vault'
    ) and (
        window[1]['assetType'] == 'pCash'
        and window[1]['transferType'] == 'Mint'
        and window[1]['toSystemAccount'] != 'Settlement'
        and window[1]['toSystemAccount'] != 'Vault'
    )

def borrow_pcash_vault(window):
    return (
        window[0]['assetType'] == 'pDebt'
        and window[0]['transferType'] == 'Mint'
        and window[0]['toSystemAccount'] == 'Vault'
    ) and (
        window[1]['assetType'] == 'pCash'
        and window[1]['transferType'] == 'Mint'
        and window[1]['toSystemAccount'] == 'Vault'
    )

def global_settlement(window):
    return (
        window[0]['assetType'] == 'pDebt'
        and window[0]['transferType'] == 'Mint'
        and window[0]['toSystemAccount'] == 'Settlement'
    ) and (
        window[1]['assetType'] == 'pCash'
        and window[1]['transferType'] == 'Mint'
        and window[1]['toSystemAccount'] == 'Settlement'
    )

def repay_pcash(window):
    return (
        window[0]['assetType'] == 'pDebt'
        and window[0]['transferType'] == 'Burn'
        and window[0]['fromSystemAccount'] != 'Settlement'
        and window[0]['fromSystemAccount'] != 'Vault'
    ) and (
        window[1]['assetType'] == 'pCash'
        and window[1]['transferType'] == 'Burn'
        and window[1]['fromSystemAccount'] != 'Settlement'
        and window[1]['fromSystemAccount'] != 'Vault'
    )

def repay_pcash_vault(window):
    return (
        window[0]['assetType'] == 'pDebt'
        and window[0]['transferType'] == 'Burn'
        and window[0]['fromSystemAccount'] == 'Vault'
    ) and (
        window[1]['assetType'] == 'pCash'
        and window[1]['transferType'] == 'Burn'
        and window[1]['fromSystemAccount'] == 'Vault'
    )

def borrow_fcash(window):
    return (
        window[0]['assetType'] == 'fCash'
        and window[0]['transferType'] == 'Mint'
    ) and (
        window[1]['assetType'] == 'fCash'
        and window[1]['transferType'] == 'Mint'
    ) and (
        # These are always emitted in pairs
        window[0]['logIndex'] == window[1]['logIndex']
    ) and (
        # Exclude System accounts
        window[0]['toSystemAccount'] is None
    )

def borrow_fcash_vault(window):
    return (
        window[0]['assetType'] == 'fCash'
        and window[0]['transferType'] == 'Mint'
    ) and (
        window[1]['assetType'] == 'fCash'
        and window[1]['transferType'] == 'Mint'
    ) and (
        # These are always emitted in pairs
        window[0]['logIndex'] == window[1]['logIndex']
    ) and (
        window[0]['toSystemAccount'] == 'Vault'
    )

def repay_fcash(window):
    return (
        window[0]['assetType'] == 'fCash' and window[0]['transferType'] == 'Burn'
    ) and (
        window[1]['assetType'] == 'fCash' and window[1]['transferType'] == 'Burn'
    ) and (
        # These are always emitted in pairs
        window[0]['logIndex'] == window[1]['logIndex']
    ) and (
        window[0]['fromSystemAccount'] is None
    )

def repay_fcash_vault(window):
    return (
        window[0]['assetType'] == 'fCash' and window[0]['transferType'] == 'Burn'
    ) and (
        window[1]['assetType'] == 'fCash' and window[1]['transferType'] == 'Burn'
    ) and (
        # These are always emitted in pairs
        window[0]['logIndex'] == window[1]['logIndex']
    ) and (
        window[0]['fromSystemAccount'] == 'Vault'
    )

def ntoken_add_liquidity(window):
    return (
        window[0]['assetType'] == 'fCash' and window[0]['transferType'] == 'Mint'
    ) and (
        window[1]['assetType'] == 'fCash' and window[1]['transferType'] == 'Mint'
    ) and (
        # These are always emitted in pairs
        window[0]['logIndex'] == window[1]['logIndex']
    ) and (
        window[0]['toSystemAccount'] == 'nToken'
    )

def ntoken_remove_liquidity(window):
    return (
        window[0]['assetType'] == 'fCash' and window[0]['transferType'] == 'Burn'
    ) and (
        window[1]['assetType'] == 'fCash' and window[1]['transferType'] == 'Burn'
    ) and (
        # These are always emitted in pairs
        window[0]['logIndex'] == window[1]['logIndex']
    ) and (
        window[0]['fromSystemAccount'] == 'nToken'
    )

def mint_ntoken(window):
    return (
        window[0]['assetType'] == 'pCash' and
        window[0]['transferType'] == 'Transfer' and
        window[0]['toSystemAccount'] == 'nToken'
    ) and (
        # TODO: this won't get emitted on legacy tokens
        window[1]['assetType'] == 'nToken' and window[1]['transferType'] == 'Mint'
    )

def redeem_ntoken(window):
    return (
        window[0]['assetType'] == 'pCash' and
        window[0]['transferType'] == 'Transfer' and
        window[0]['fromSystemAccount'] == 'nToken'
    ) and (
        # TODO: this won't get emitted on legacy tokens
        window[1]['assetType'] == 'nToken' and window[1]['transferType'] == 'Burn'
    )

def buy_fcash_trade(window):
    return (
        window[0]['assetType'] == 'pCash' and
        window[0]['transferType'] == 'Transfer' and
        window[0]['fromSystemAccount'] != 'Vault' and
        window[0]['toSystemAccount'] == 'nToken'
    ) and (
        window[1]['assetType'] == 'pCash' and
        window[1]['transferType'] == 'Transfer' and
        window[1]['toSystemAccount'] == 'Fee Reserve'
     ) and (
        window[2]['transferType'] == 'Transfer' and
        window[2]['fromSystemAccount'] == 'nToken' and
        window[2]['toSystemAccount'] != 'nToken' and
        window[2]['toSystemAccount'] != 'Vault' and
        window[2]['assetType'] == 'fCash'
    )

def buy_fcash_trade_vault(window):
    return (
        window[0]['assetType'] == 'pCash' and
        window[0]['transferType'] == 'Transfer' and
        window[0]['fromSystemAccount'] == 'Vault' and
        window[0]['toSystemAccount'] == 'nToken'
    ) and (
        window[1]['assetType'] == 'pCash' and
        window[1]['transferType'] == 'Transfer' and
        window[1]['toSystemAccount'] == 'Fee Reserve'
     ) and (
        window[2]['transferType'] == 'Transfer' and
        window[2]['fromSystemAccount'] == 'nToken' and
        window[2]['toSystemAccount'] != 'nToken' and
        window[2]['toSystemAccount'] == 'Vault' and
        window[2]['assetType'] == 'fCash'
    )

def deleverage_ntoken(window):
    return (
        window[0]['assetType'] == 'pCash' and
        window[0]['transferType'] == 'Transfer' and
        window[0]['fromSystemAccount'] == 'nToken' and
        window[0]['toSystemAccount'] == 'nToken'
    ) and (
        window[1]['assetType'] == 'pCash' and
        window[1]['transferType'] == 'Transfer' and
        window[1]['toSystemAccount'] == 'Fee Reserve'
     ) and (
        window[2]['transferType'] == 'Transfer' and
        window[2]['fromSystemAccount'] == 'nToken' and
        window[2]['toSystemAccount'] == 'nToken' and
        window[2]['assetType'] == 'fCash'
    )

def sell_fcash_trade(window):
    return (
        window[0]['assetType'] == 'pCash' and
        window[0]['transferType'] == 'Transfer' and
        window[0]['fromSystemAccount'] == 'nToken' and
        window[0]['toSystemAccount'] != 'Vault'
    ) and (
        window[1]['assetType'] == 'pCash' and
        window[1]['transferType'] == 'Transfer' and
        window[1]['toSystemAccount'] == 'Fee Reserve'
     ) and (
        window[2]['transferType'] == 'Transfer' and
        window[2]['fromSystemAccount'] != 'Vault' and
        window[2]['toSystemAccount'] == 'nToken' and
        window[2]['assetType'] == 'fCash'
    )

def sell_fcash_trade_vault(window):
    return (
        window[0]['assetType'] == 'pCash' and
        window[0]['transferType'] == 'Transfer' and
        window[0]['fromSystemAccount'] == 'nToken' and
        window[0]['toSystemAccount'] == 'Vault'
    ) and (
        window[1]['assetType'] == 'pCash' and
        window[1]['transferType'] == 'Transfer' and
        window[1]['toSystemAccount'] == 'Fee Reserve'
     ) and (
        window[2]['transferType'] == 'Transfer' and
        window[2]['fromSystemAccount'] == 'Vault' and
        window[2]['toSystemAccount'] == 'nToken' and
        window[2]['assetType'] == 'fCash'
    )

def vault_entry_transfer(window):
    # This looks like a withdraw, but it is done by the vault
    return not (
        # A withdraw is not preceded by a burn of pDebt
        window[0]['transferType'] == 'Mint' and window[0]['assetType'] == 'pDebt'
    ) and (
        window[1]['transferType'] == 'Burn'
        and window[1]['assetType'] == 'pCash'
        and window[1]['fromSystemAccount'] == 'Vault'
    )

def vault_entry_transfer_2(window):
    # This looks like a withdraw, but it is done by the vault
    return not (
        # A withdraw is not preceded by a burn of pDebt
        window[0]['transferType'] == 'Mint' and window[0]['assetType'] == 'pDebt'
    ) and (
        window[1]['transferType'] == 'Burn'
        and window[1]['assetType'] == 'pCash'
        and window[1]['fromSystemAccount'] == 'Vault'
    )

def vault_fees(window):
    return (
        window[0]['assetType'] == 'pCash' and
        window[0]['transferType'] == 'Transfer' and
        window[0]['toSystemAccount'] == 'Fee Reserve'
    ) and (
        window[1]['assetType'] == 'pCash' and
        window[1]['transferType'] == 'Transfer' and
        window[1]['toSystemAccount'] == 'nToken'
    )

def vault_redeem(window):
    # Emits a mint / transfer / burn to signify profits sent to the account
    return (
        window[0]['transferType'] == 'Mint' and
        window[0]['assetType'] == 'pCash' and
        window[0]['toSystemAccount'] == 'Vault'
    ) and (
        window[1]['transferType'] == 'Transfer' and
        window[1]['assetType'] == 'pCash' and
        window[1]['fromSystemAccount'] == 'Vault'
    ) and (
        window[2]['transferType'] == 'Burn' and
        window[2]['assetType'] == 'pCash' and
        window[2]['from'] == window[1]['to']
    )

def vault_exit_lend_at_zero(window):
    return (
        window[0]['transferType'] == 'Transfer' and
        window[0]['fromSystemAccount'] == 'Vault' and
        window[0]['toSystemAccount'] == 'Settlement' and
        window[0]['assetType'] == 'pCash'
    ) and (
        window[1]['transferType'] == 'Mint' and
        window[1]['assetType'] == 'fCash'
    ) and (
        window[2]['transferType'] == 'Mint' and
        window[2]['assetType'] == 'fCash'
    ) and (
        # Settlement mints an fCash pair
        window[1]['logIndex'] == window[2]['logIndex'] and
        window[1]['toSystemAccount'] == 'Settlement'
    ) and (
        # Settlement transfers the positive side to the vault
        window[3]['transferType'] == 'Transfer' and
        window[3]['fromSystemAccount'] == 'Settlement' and
        window[3]['toSystemAccount'] == 'Vault' and
        window[3]['assetType'] == 'fCash' and
        window[3]['value'] > 0
    )

def vault_entry(window):
    return ( 
        not vault_settle(window)
    ) and (
        not vault_roll(window)
    ) and (
        window[2]['transferType'] == 'Mint' and
        window[2]['assetType'] == 'Vault Debt'
    ) and (
        window[3]['transferType'] == 'Mint' and
        window[3]['assetType'] == 'Vault Share'
    )

def vault_exit(window):
    return (
        window[0]['transferType'] == 'Burn' and
        window[0]['assetType'] == 'Vault Debt'
    ) and (
        window[1]['transferType'] == 'Burn' and
        window[1]['assetType'] == 'Vault Share'
    # ) and not (
    #     # This pattern is a vault settlement
    #     window[0]['maturity'] <= window[0]['timestamp'] and
    #     window[1]['maturity'] <= window[1]['timestamp']
    )

def vault_roll(window):
    return not (
        vault_settle(window)
    ) and (
        window[0]['transferType'] == 'Burn' and
        window[0]['assetType'] == 'Vault Debt' and
        window[0]['value'] != 0
    ) and (
        window[1]['transferType'] == 'Burn' and
        window[1]['assetType'] == 'Vault Share' and
        window[1]['value'] != 0
    ) and (
        window[2]['transferType'] == 'Mint' and
        window[2]['assetType'] == 'Vault Debt' and
        window[2]['value'] != 0
    ) and (
        window[3]['transferType'] == 'Mint' and
        window[3]['assetType'] == 'Vault Share' and
        window[3]['value'] != 0
    )

def vault_settle(window):
    return (
        window[0]['transferType'] == 'Burn' and
        window[0]['assetType'] == 'Vault Debt' and
        window[0]['maturity'] <= window[0]['timestamp']
    ) and (
        window[1]['transferType'] == 'Burn' and
        window[1]['assetType'] == 'Vault Share' and
        window[1]['maturity'] <= window[1]['timestamp']
    ) and (
        window[2]['transferType'] == 'Mint' and
        window[2]['assetType'] == 'Vault Debt' and
        window[2]['maturity'] == PRIME_CASH_VAULT_MATURITY
    ) and (
        window[3]['transferType'] == 'Mint' and
        window[3]['assetType'] == 'Vault Share' and
        window[3]['maturity'] == PRIME_CASH_VAULT_MATURITY
    )

def vault_deleverage_fcash(window):
    return (
        window[0]['transferType'] == 'Mint' and
        window[0]['assetType'] == 'Vault Cash'
    ) and (
        window[1]['transferType'] == 'Transfer' and
        window[1]['assetType'] == 'Vault Share'
    )

def vault_withdraw_cash(window):
    return (
        window[0]['transferType'] == 'Transfer' and
        window[0]['fromSystemAccount'] == 'Vault' and
        window[0]['assetType'] == 'pCash' and
        window[0]['toSystemAccount'] is None
    ) and (
        window[1]['transferType'] == 'Burn' and
        window[1]['fromSystemAccount'] is None and
        window[1]['assetType'] == 'pCash'
    )

def vault_burn_cash(window):
    return (
        window[0]['transferType'] == 'Burn' and
        window[0]['assetType'] == 'Vault Cash'
    )

def vault_liquidate_excess_cash(window):
    return (
        window[0]['transferType'] == 'Transfer' and
        window[0]['assetType'] == 'pCash' and
        window[0]['fromSystemAccount'] == "Vault"
    ) and (
        window[1]['transferType'] == 'Burn' and
        window[1]['assetType'] == 'pCash' and
        window[1]['fromSystemAccount'] is None
    ) and (
        window[2]['transferType'] == 'Burn' and
        window[2]['assetType'] == 'Vault Cash'
    ) and (
        window[3]['transferType'] == 'Mint' and
        window[3]['assetType'] == 'pCash' and
        window[3]['fromSystemAccount'] is None
    ) and (
        window[4]['transferType'] == 'Transfer' and
        window[4]['assetType'] == 'pCash' and
        window[4]['toSystemAccount'] == "Vault"
    ) and (
        window[5]['transferType'] == 'Mint' and
        window[5]['assetType'] == 'Vault Cash'
    )

def vault_settle_cash(window):
    return (
        window[0]['transferType'] == 'Burn' and
        window[0]['assetType'] == 'Vault Cash'
    ) and (
        window[1]['transferType'] == 'Mint' and
        window[1]['assetType'] == 'Vault Cash' and
        window[1]['maturity'] == PRIME_CASH_VAULT_MATURITY
    )

def vault_deleverage_prime_debt(window):
    return (
        window[0]['transferType'] == 'Burn' and
        window[0]['assetType'] == 'Vault Debt' and 
        window[0]['maturity'] == PRIME_CASH_VAULT_MATURITY
    ) and (
        window[1]['transferType'] == 'Transfer' and
        window[1]['assetType'] == 'Vault Share' and
        window[1]['maturity'] == PRIME_CASH_VAULT_MATURITY
    )

def vault_liquidate_cash_balance(window):
    # Liquidator receives cash and sends fCash
    return (
        window[0]['transferType'] == 'Transfer' and
        window[0]['fromSystemAccount'] == 'Vault' and
        window[0]['assetType'] == 'pCash'
    ) and (
        window[1]['transferType'] == 'Transfer' and
        window[1]['toSystemAccount'] == 'Vault' and
        window[1]['assetType'] == 'fCash'
    # Account burns its debt and cash
    ) and (
        window[2]['transferType'] == 'Burn' and
        window[2]['assetType'] == 'Vault Debt'
    ) and (
        window[3]['transferType'] == 'Burn' and
        window[3]['assetType'] == 'Vault Cash'
    # Vault burns its debt balance
    ) and (
        window[4]['transferType'] == 'Burn' and
        window[4]['fromSystemAccount'] == 'Vault' and
        window[4]['assetType'] == 'fCash'
    ) and (
        window[5]['transferType'] == 'Burn' and
        window[5]['fromSystemAccount'] == 'Vault' and
        window[5]['assetType'] == 'fCash'
    )

def vault_secondary_borrow(window):
    # Vault mints fCash or pCash debt
    return (
        window[0]['transferType'] == 'Mint' and
        window[0]['toSystemAccount'] == 'Vault' and
        (window[0]['assetType'] == 'fCash' or window[0]['assetType'] == 'pDebt')
    ) and (
        window[1]['transferType'] == 'Mint' and
        window[1]['toSystemAccount'] == 'Vault' and
        (window[1]['assetType'] == 'fCash' or window[1]['assetType'] == 'pCash')
    ) and (
        window[2]['transferType'] == 'Mint' and
        window[2]['assetType'] == 'Vault Debt'
    ) and (
        # All debts are marked in the same currency
        window[2]['underlying'] == window[0]['underlying'] and
        window[2]['underlying'] == window[1]['underlying']
    ) and (
    #     window[3]['assetType'] == 'pcash' and
    #     window[3]['fromSystemAccount'] == 'Vault' and
    #     window[3]['transferType'] == 'Burn'
    # ) and (
        # Secondary borrows are not followed by minting vault shares
        window[3]['assetType'] != 'Vault Share'
    )

def vault_secondary_repay(window):
    # Vault repays fCash or pCash debt
    return (
        window[0]['transferType'] == 'Burn' and
        window[0]['fromSystemAccount'] == 'Vault' and
        (window[0]['assetType'] == 'fCash' or window[0]['assetType'] == 'pDebt')
    ) and (
        window[1]['transferType'] == 'Burn' and
        window[1]['fromSystemAccount'] == 'Vault' and
        (window[1]['assetType'] == 'fCash' or window[1]['assetType'] == 'pCash')
    ) and (
        window[2]['transferType'] == 'Burn' and
        window[2]['assetType'] == 'Vault Debt'
    ) and (
        # All debts are marked in the same currency
        window[2]['underlying'] == window[0]['underlying'] and
        window[2]['underlying'] == window[1]['underlying']
    ) and (
        # Secondary borrows are not followed by burning vault shares
        window[3]['assetType'] != 'Vault Share'
    ) and not (
        # Secondary repay is not followed by minting prime debt, this is
        # a vault settle with cash repayment
        window[3]['transferType'] == 'Mint' and
        window[3]['assetType'] == 'Vault Debt' and
        window[3]['maturity'] == PRIME_CASH_VAULT_MATURITY
    )

def vault_secondary_deposit(window):
    return (
        window[0]['transferType'] == 'Mint' and
        window[0]['assetType'] == 'pCash' and
        window[0]['toSystemAccount'] == 'Vault'
    )

def vault_secondary_settle(window):
    return (
        window[0]['transferType'] == 'Burn' and
        window[0]['assetType'] == 'Vault Debt' and
        window[0]['maturity'] <= window[0]['timestamp']
    ) and (
        window[1]['transferType'] == 'Mint' and
        window[1]['assetType'] == 'Vault Debt' and
        window[1]['maturity'] == PRIME_CASH_VAULT_MATURITY
    ) and (
        window[0]['from'] == window[1]['to'] and
        window[0]['underlying'] == window[1]['underlying']
    )

bundleCriteria = [
    # Window Size == 1
    {'bundleName': 'Deposit', 'windowSize': 1, 'lookBehind': 1, 'canStart': True, 'func': deposit},
    {'bundleName': 'Mint pCash Fee', 'windowSize': 1, 'func': mint_pcash_fee},
    {'bundleName': 'Withdraw', 'windowSize': 1, 'lookBehind': 1, 'canStart': True, 'func': withdraw},
    # This will rewrite the previous deposit bundle if it matches
    {'bundleName': 'Deposit and Transfer', 'windowSize': 1, 'lookBehind': 1, 'rewrite': True, 'func': deposit_transfer},
    # NOTE: ensure transfer asset runs after deposit and transfer as a fall through catch
    {'bundleName': 'Transfer Asset', 'windowSize': 1, 'func': transfer_asset},
    {'bundleName': 'Transfer Incentive', 'windowSize': 1, 'func': transfer_incentive},
    {'bundleName': 'Vault Entry Transfer', 'windowSize': 1, 'lookBehind': 1, 'func': vault_entry_transfer},
    # This is a secondary vault entry transfer
    {'bundleName': 'Vault Entry Transfer', 'windowSize': 2, 'lookBehind': 1, 'bundleSize': 1, 'func': vault_entry_transfer_2},
    {'bundleName': 'Vault Secondary Deposit', 'windowSize': 2, 'bundleSize': 1, 'func': vault_secondary_deposit},
    {'bundleName': 'nToken Purchase Negative Residual', 'windowSize': 4, 'lookBehind': 1, 'func': ntoken_purchase_negative_residual},
    {'bundleName': 'nToken Purchase Positive Residual', 'windowSize': 2, 'lookBehind': 1, 'func': ntoken_purchase_positive_residual},
    {'bundleName': 'nToken Residual Transfer', 'windowSize': 1, 'lookBehind': 1, 'func': ntoken_residual_transfer},

    # Window Size == 1, No Look Behind
    {'bundleName': 'Settle Cash', 'windowSize': 1, 'func': settle_cash},
    {'bundleName': 'Settle fCash', 'windowSize': 1, 'func': settle_fcash},
    {'bundleName': 'Settle Cash nToken', 'windowSize': 1, 'func': settle_cash_ntoken},
    {'bundleName': 'Settle fCash nToken', 'windowSize': 1, 'func': settle_fcash_ntoken},

    # Window Size == 2
    {'bundleName': 'Borrow Prime Cash', 'windowSize': 2, 'func': borrow_pcash},
    {'bundleName': 'Global Settlement', 'windowSize': 2, 'func': global_settlement},
    {'bundleName': 'Repay Prime Cash', 'windowSize': 2, 'func': repay_pcash},
    {'bundleName': 'Borrow fCash', 'windowSize': 2, 'func': borrow_fcash},
    {'bundleName': 'Repay fCash', 'windowSize': 2, 'func': repay_fcash},
    {'bundleName': 'nToken Add Liquidity', 'windowSize': 2, 'func': ntoken_add_liquidity},
    {'bundleName': 'nToken Remove Liquidity', 'windowSize': 2, 'func': ntoken_remove_liquidity},
    {'bundleName': 'Mint nToken', 'windowSize': 2, 'func': mint_ntoken},
    {'bundleName': 'Redeem nToken', 'windowSize': 2, 'func': redeem_ntoken},

    # Window Size == 3
    {'bundleName': 'Buy fCash', 'windowSize': 3, 'func': buy_fcash_trade},
    {'bundleName': 'nToken Deleverage', 'windowSize': 3, 'func': deleverage_ntoken},
    {'bundleName': 'Sell fCash', 'windowSize': 3, 'func': sell_fcash_trade},

    # Vault Transactions
    {'bundleName': 'Borrow Prime Cash [Vault]', 'windowSize': 2, 'func': borrow_pcash_vault},
    {'bundleName': 'Repay Prime Cash [Vault]', 'windowSize': 2, 'func': repay_pcash_vault},
    {'bundleName': 'Buy fCash [Vault]', 'windowSize': 3, 'func': buy_fcash_trade_vault},
    {'bundleName': 'Sell fCash [Vault]', 'windowSize': 3, 'func': sell_fcash_trade_vault},
    {'bundleName': 'Borrow fCash [Vault]', 'windowSize': 2, 'func': borrow_fcash_vault},
    {'bundleName': 'Repay fCash [Vault]', 'windowSize': 2, 'func': repay_fcash_vault},
    {'bundleName': 'Vault Fees', 'windowSize': 2, 'func': vault_fees},
    {'bundleName': 'Vault Redeem', 'windowSize': 3, 'func': vault_redeem},
    {'bundleName': 'Vault Lend at Zero', 'windowSize': 4, 'func': vault_exit_lend_at_zero},
    # Vault Share & Vault Debt Mint & Burn
    {'bundleName': 'Vault Roll', 'lookBehind': 2, 'windowSize': 2, 'rewrite': True, 'func': vault_roll},
    {'bundleName': 'Vault Entry', 'windowSize': 2, 'lookBehind': 2, 'func': vault_entry},
    {'bundleName': 'Vault Exit', 'windowSize': 2, 'func': vault_exit},
    {'bundleName': 'Vault Settle', 'lookBehind': 2, 'windowSize': 2, 'rewrite': True, 'func': vault_settle},
    {'bundleName': 'Vault Deleverage fCash', 'windowSize': 2, 'func': vault_deleverage_fcash},
    {'bundleName': 'Vault Deleverage Prime Debt', 'windowSize': 2, 'func': vault_deleverage_prime_debt},
    {'bundleName': 'Vault Liquidate Cash', 'windowSize': 6, 'func': vault_liquidate_cash_balance},
    {'bundleName': 'Vault Withdraw Cash', 'windowSize': 2, 'func': vault_withdraw_cash},
    {'bundleName': 'Vault Burn Cash', 'windowSize': 1, 'func': vault_burn_cash},
    {'bundleName': 'Vault Settle Cash', 'windowSize': 1, 'lookBehind': 1, 'rewrite': True, 'func': vault_settle_cash},
    # Vault Secondary Debt
    {'bundleName': 'Vault Secondary Borrow', 'windowSize': 2, 'lookBehind': 2, 'bundleSize': 1, 'func': vault_secondary_borrow},
    {'bundleName': 'Vault Secondary Repay', 'windowSize': 2, 'lookBehind': 2, 'bundleSize': 1, 'func': vault_secondary_repay},
    {'bundleName': 'Vault Secondary Settle', 'windowSize': 2, 'func': vault_secondary_settle},
    {'bundleName': 'Vault Liquidate Excess Cash', 'windowSize': 1, 'lookBehind': 5, 'rewrite': True, 'func': vault_liquidate_excess_cash},
]
