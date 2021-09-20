certoraRun.py contracts/external/actions/AccountAction.sol contracts/mocks/certora/BalanceStateHarness.sol \
    contracts/mocks/certora/DummyERC20A.sol \
    --verify BalanceStateHarness:certora/asset/BalanceState.spec \
    --solc solc7.6 \
    --optimistic_loop \
    --loop_iter 1 \
    --cache BalanceHandlerNotional \
    --packages_path ${BROWNIE_PATH}/packages \
    --packages @openzeppelin=${BROWNIE_PATH}/packages/OpenZeppelin/openzeppelin-contracts@3.4.2-solc-0.7 compound-finance=${BROWNIE_PATH}/packages/compound-finance \
    --solc_args "['--optimize']" --msg "BalanceState - $1" --javaArgs '"-Dverbose.times -Dverbose.cache"' --staging --rule integrity_depositAssetToken_old
