perl -0777 -i -pe 's/internal\s*constant/public constant/g' contracts/global/Constants.sol
perl -0777 -i -pe 's/BalanceState memory/BalanceState storage/g' contracts/internal/balances/BalanceHandler.sol
echo "Comment out loadBalanceState in BalanceHandler.sol"