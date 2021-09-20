// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/markets/CashGroup.sol";

contract CashGroupHarness {
    using CashGroup for CashGroupParameters;

    function getMaxMarketIndex(uint256 currencyId) public view returns (uint8) {
        return CashGroup.getMaxMarketIndex(currencyId);
    }

    function getRateScalar(
        uint256 currencyId,
        uint256 marketIndex,
        uint256 timeToMaturity
    ) public returns (int256 rateScalar) {
        CashGroupParameters memory cg = CashGroup.buildCashGroupStateful(currencyId);
        CashGroupParameters memory cgv = CashGroup.buildCashGroupView(currencyId);
        rateScalar = cg.getRateScalar(marketIndex, timeToMaturity);
        assert(cgv.getRateScalar(marketIndex, timeToMaturity) == rateScalar);
    }

    function getTotalFee(uint256 currencyId) public returns (uint256 fee) {
        CashGroupParameters memory cg = CashGroup.buildCashGroupStateful(currencyId);
        CashGroupParameters memory cgv = CashGroup.buildCashGroupView(currencyId);
        fee = cg.getTotalFee();
        assert(cgv.getTotalFee() == fee);
    }

    function getReserveFeeShare(uint256 currencyId) public returns (int256 share) {
        CashGroupParameters memory cg = CashGroup.buildCashGroupStateful(currencyId);
        CashGroupParameters memory cgv = CashGroup.buildCashGroupView(currencyId);
        share = cg.getReserveFeeShare();
        assert(cgv.getReserveFeeShare() == share);
        return share;
    }

    function getLiquidityHaircut(uint256 currencyId, uint256 assetType)
        public
        returns (uint256 haircut)
    {
        CashGroupParameters memory cg = CashGroup.buildCashGroupStateful(currencyId);
        CashGroupParameters memory cgv = CashGroup.buildCashGroupView(currencyId);
        haircut = cg.getLiquidityHaircut(assetType);
        assert(cgv.getLiquidityHaircut(assetType) == haircut);
    }

    function getfCashHaircut(uint256 currencyId) public returns (uint256 haircut) {
        CashGroupParameters memory cg = CashGroup.buildCashGroupStateful(currencyId);
        CashGroupParameters memory cgv = CashGroup.buildCashGroupView(currencyId);
        haircut = cg.getfCashHaircut();
        assert(cgv.getfCashHaircut() == haircut);
    }

    function getDebtBuffer(uint256 currencyId) public returns (uint256 buffer) {
        CashGroupParameters memory cg = CashGroup.buildCashGroupStateful(currencyId);
        CashGroupParameters memory cgv = CashGroup.buildCashGroupView(currencyId);
        buffer = cg.getDebtBuffer();
        assert(cgv.getDebtBuffer() == buffer);
    }

    function getRateOracleTimeWindow(uint256 currencyId) public returns (uint256 window) {
        CashGroupParameters memory cg = CashGroup.buildCashGroupStateful(currencyId);
        CashGroupParameters memory cgv = CashGroup.buildCashGroupView(currencyId);
        window = cg.getRateOracleTimeWindow();
        assert(cgv.getRateOracleTimeWindow() == window);
    }

    function getSettlementPenalty(uint256 currencyId) public returns (uint256 penalty) {
        CashGroupParameters memory cg = CashGroup.buildCashGroupStateful(currencyId);
        CashGroupParameters memory cgv = CashGroup.buildCashGroupView(currencyId);
        penalty = cg.getSettlementPenalty();
        assert(cgv.getSettlementPenalty() == penalty);
    }

    function getLiquidationfCashHaircut(uint256 currencyId) public returns (uint256 haircut) {
        CashGroupParameters memory cg = CashGroup.buildCashGroupStateful(currencyId);
        CashGroupParameters memory cgv = CashGroup.buildCashGroupView(currencyId);
        haircut = cg.getLiquidationfCashHaircut();
        assert(cgv.getLiquidationfCashHaircut() == haircut);
    }

    function getLiquidationDebtBuffer(uint256 currencyId) public returns (uint256 buffer) {
        CashGroupParameters memory cg = CashGroup.buildCashGroupStateful(currencyId);
        CashGroupParameters memory cgv = CashGroup.buildCashGroupView(currencyId);
        buffer = cg.getLiquidationDebtBuffer();
        assert(cgv.getLiquidationDebtBuffer() == buffer);
    }

    function deserializeCashGroupStorage(uint256 currencyId)
        public
        view
        returns (CashGroupSettings memory)
    {
        return CashGroup.deserializeCashGroupStorage(currencyId);
    }

    // function setCashGroupStorage(
    //     uint256 currencyId,
    //     uint8 maxMarketIndex,
    //     uint8 rateOracleTimeWindowMin,
    //     uint8 totalFeeBPS,
    //     uint8 reserveFeeShare,
    //     uint8 debtBuffer5BPS,
    //     uint8 fCashHaircut5BPS,
    //     uint8 settlementPenaltyRate5BPS,
    //     uint8 liquidationfCashHaircut5BPS,
    //     uint8 liquidationDebtBuffer5BPS,
    //     uint8[] memory liquidityTokenHaircuts,
    //     uint8[] memory rateScalars
    // ) external {
    //     CashGroup.setCashGroupStorage(
    //         currencyId,
    //         CashGroupSettings(
    //             maxMarketIndex,
    //             rateOracleTimeWindowMin,
    //             totalFeeBPS,
    //             reserveFeeShare,
    //             debtBuffer5BPS,
    //             fCashHaircut5BPS,
    //             settlementPenaltyRate5BPS,
    //             liquidationfCashHaircut5BPS,
    //             liquidationDebtBuffer5BPS,
    //             liquidityTokenHaircuts,
    //             rateScalars
    //         )
    //     );
    // }
}
