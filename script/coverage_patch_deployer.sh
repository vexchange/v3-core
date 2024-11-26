OPTIMIZED_STABLE_HASH=$(cat script/optimized-deployer-meta | jq -r '.stable_hash')
UNOPTIMIZED_STABLE_HASH=$(cat script/unoptimized-deployer-meta | jq -r '.stable_hash')

OPTIMIZED_CONSTANT_PRODUCT_HASH=$(cat script/optimized-deployer-meta | jq -r '.constant_product_hash')
UNOPTIMIZED_CONSTANT_PRODUCT_HASH=$(cat script/unoptimized-deployer-meta | jq -r '.constant_product_hash')

OPTIMIZED_ORACLE_CALLER_HASH=$(cat script/optimized-deployer-meta | jq -r '.oracle_caller_hash')
UNOPTIMIZED_ORACLE_CALLER_HASH=$(cat script/unoptimized-deployer-meta | jq -r '.oracle_caller_hash')

OPTIMIZED_FACTORY_HASH=$(cat script/optimized-deployer-meta | jq -r '.factory_hash')
UNOPTIMIZED_FACTORY_HASH=$(cat script/unoptimized-deployer-meta | jq -r '.factory_hash')

if [ "$FOUNDRY_PROFILE" == "coverage" ] || [ "$FOUNDRY_PROFILE" == "coverage-integration" ]
then
    echo "Running with coverage profile, patching ReservoirDeployer"
    sed -i "s/$OPTIMIZED_STABLE_HASH/$UNOPTIMIZED_STABLE_HASH/g" src/ReservoirDeployer.sol
    sed -i "s/$OPTIMIZED_CONSTANT_PRODUCT_HASH/$UNOPTIMIZED_CONSTANT_PRODUCT_HASH/g" src/ReservoirDeployer.sol
    sed -i "s/$OPTIMIZED_ORACLE_CALLER_HASH/$UNOPTIMIZED_ORACLE_CALLER_HASH/g" src/ReservoirDeployer.sol
    sed -i "s/$OPTIMIZED_FACTORY_HASH/$UNOPTIMIZED_FACTORY_HASH/g" src/ReservoirDeployer.sol
else
    echo "Running with default profile, patching ReservoirDeployer"
    sed -i "s/$UNOPTIMIZED_STABLE_HASH/$OPTIMIZED_STABLE_HASH/g" src/ReservoirDeployer.sol
    sed -i "s/$UNOPTIMIZED_CONSTANT_PRODUCT_HASH/$OPTIMIZED_CONSTANT_PRODUCT_HASH/g" src/ReservoirDeployer.sol
    sed -i "s/$UNOPTIMIZED_ORACLE_CALLER_HASH/$OPTIMIZED_ORACLE_CALLER_HASH/g" src/ReservoirDeployer.sol
    sed -i "s/$UNOPTIMIZED_FACTORY_HASH/$OPTIMIZED_FACTORY_HASH/g" src/ReservoirDeployer.sol
fi
