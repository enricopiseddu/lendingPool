// SPDX-License-Identifier: CC-BY-4.0

/// @title An high-level implementation of a Lending Pool for ERC20 tokens in DeFi
/// @author Enrico Piseddu

pragma solidity >=0.7.0 <0.9.0;

import "WadRayMath.sol";
import "ERC20.sol";
import "SafeMath.sol";

library LPlibrary{

    using SafeMath for uint256;
    using WadRayMath for uint256;
    
    struct ReserveData{
        address adr;
        uint256 cumulatedLiquidityIndex;
        uint256 cumulatedVariableBorrowIndex;
        uint256 lastUpdateTimestamp;
        uint256 totalVariableBorrows;
        uint256 totalLiquidity;
        uint256 variableBorrowRate;
        uint256 currentLiquidityRate;
        uint256 price; //price of 1 token, in ETH
        uint256 decimals; 
        uint256 baseLtvAsCollateral;
        uint256 liquidationThreshold;
    }

    uint256 constant OPTIMAL_UTILIZATION_RATE = 0.8 * 1e27; //express in ray
    uint256 constant EXCESS_UTILIZATION_RATE = 0.2 * 1e27; //express in ray

    uint256 public constant LIQUIDATION_BONUS = 5; //express in percentage

    uint256 constant baseVariableBorrowRate = 1e27;
    uint256 constant r_slope1 = 8e27;
    uint256 constant r_slope2 = 200e27;

    uint256 constant SECONDS_PER_YEAR = 60*60*24*365;

    function updateInterestRatesAndTimestamp(ReserveData storage _self, uint256 _liquidityAdded, uint256 _liquidityTaken) internal{
        uint256 liquidityAvailable = ERC20(_self.adr).balanceOf(address(this));
        (uint256 newLiquidityRate, uint256 newVariableRate) = calculateInterestRates(liquidityAvailable.add(_liquidityAdded).sub(_liquidityTaken), _self.totalVariableBorrows);

        _self.currentLiquidityRate = newLiquidityRate;
        _self.variableBorrowRate = newVariableRate;
        _self.lastUpdateTimestamp = block.timestamp;
    }

    function calculateInterestRates(uint256 _availableLiquidity, uint256 _totalBorrows) public pure 
                                                                        returns(uint256 currentLiquidityRate, 
                                                                                uint256 currentVariableBorrowRate){
        uint256 utilizationRate = (_totalBorrows == 0 && _availableLiquidity == 0)
            ? 0
            : _totalBorrows.rayDiv(_availableLiquidity.add(_totalBorrows));

        if (utilizationRate > OPTIMAL_UTILIZATION_RATE){

            uint256 excessUtilizationRateRatio = utilizationRate
                .sub(OPTIMAL_UTILIZATION_RATE)
                .rayDiv(EXCESS_UTILIZATION_RATE);

           currentVariableBorrowRate = baseVariableBorrowRate.add(r_slope1).add(
                r_slope2.rayMul(excessUtilizationRateRatio)
            ); 
        }
        else{
            currentVariableBorrowRate = baseVariableBorrowRate.add(
                utilizationRate.rayDiv(OPTIMAL_UTILIZATION_RATE).rayMul(r_slope1)
            );
        }

        currentLiquidityRate = currentVariableBorrowRate.rayMul(utilizationRate);
    }


    function calculateHealthFactorFromBalancesInternal(uint256 collateralBalanceETH,
                                                        uint256 borrowBalanceETH,
                                                        uint256 totalFeesETH,
                                                        uint256 liquidationThreshold
        ) internal pure returns (uint256) {
            if (borrowBalanceETH == 0) return 2**256-1; // maximum health factor because of no borrows

            return
                (collateralBalanceETH.mul(liquidationThreshold).div(100)).wadDiv(
                    borrowBalanceETH.add(totalFeesETH)
                );
    }


    function calculateLinearInterest(uint256 _rate, uint256 _lastUpdateTimestamp)
        internal
        view
        returns (uint256)
    {
        
        uint256 timeDifference = block.timestamp.sub(_lastUpdateTimestamp);

        uint256 timeDelta = timeDifference.wadToRay().rayDiv(SECONDS_PER_YEAR.wadToRay());

        return _rate.rayMul(timeDelta).add(WadRayMath.ray());
    }


    function calculateCompoundedInterest(uint256 _rate, uint256 _lastUpdateTimestamp)
        internal
        view
        returns (uint256)
    {
        uint256 timeDifference = block.timestamp.sub(_lastUpdateTimestamp);

        uint256 ratePerSecond = _rate.div(SECONDS_PER_YEAR);

        return ratePerSecond.add(WadRayMath.ray()).rayPow(timeDifference);
    }


    function updateIndexes(ReserveData storage _self) internal{
        uint256 totalBorrowsReserve = _self.totalVariableBorrows;
        
        uint256 variableBorrowRate;

        ERC20 reserve = ERC20(_self.adr);
        uint256 totalLiquidity = reserve.balanceOf(address(this));
        uint256 utilizationRate = (totalLiquidity == 0) ? 0 : (totalBorrowsReserve.wadDiv(totalLiquidity));


        variableBorrowRate = (utilizationRate <= OPTIMAL_UTILIZATION_RATE) ? baseVariableBorrowRate.add(utilizationRate.rayDiv(OPTIMAL_UTILIZATION_RATE).rayMul(r_slope1)) :
                                                            baseVariableBorrowRate.add(r_slope1).add(r_slope2.rayMul( utilizationRate.sub(OPTIMAL_UTILIZATION_RATE).rayDiv(EXCESS_UTILIZATION_RATE) ));

        _self.variableBorrowRate = variableBorrowRate;

        uint256 currentLiquidityRate = variableBorrowRate.rayMul(utilizationRate);
        

        if(totalBorrowsReserve > 0){
            //update Ci
            uint256 cumulatedLiquidityInterest = LPlibrary.calculateLinearInterest(currentLiquidityRate, _self.lastUpdateTimestamp);

            _self.cumulatedLiquidityIndex = cumulatedLiquidityInterest.rayMul(_self.cumulatedLiquidityIndex);


            //update Bvc
            uint256 cumulatedVariableBorrowInterest = LPlibrary.calculateCompoundedInterest(variableBorrowRate, _self.lastUpdateTimestamp);

            _self.cumulatedVariableBorrowIndex = cumulatedVariableBorrowInterest.rayMul(_self.cumulatedVariableBorrowIndex);
        }
    }


    function calculateAvaiableCollateralToLiquidate(uint256 _collateralPrice, uint256 _principalPrice, uint256 _purchaseAmount, uint256 _userCollateralBalance) internal pure 
        returns(uint256 collateralAmount, uint256 principalNeeded){

        //uint256 collateralPrice = reserves[_collateral].price;
        //uint256 principalPrice = reserves[_principal].price;

        uint256 maxAmountCollateralToLiquidate= (_principalPrice
                    .mul(_purchaseAmount)
                    .div(_collateralPrice)
                    .mul(LIQUIDATION_BONUS) // 5%
                    .div(100))
                    .add(
                        _principalPrice
                        .mul(_purchaseAmount)
                        .div(_collateralPrice)
                    ); //liquidator obtains the respective amount of collateral + bonus 5%

        if (maxAmountCollateralToLiquidate > _userCollateralBalance){
            collateralAmount = _userCollateralBalance;
            principalNeeded = _collateralPrice
                .mul(collateralAmount)
                .div(_principalPrice)
                .mul(100)
                .div(LIQUIDATION_BONUS);
        }
        else{
            collateralAmount = maxAmountCollateralToLiquidate;
            principalNeeded = _purchaseAmount;
        }

    }


    function getNormalizedIncome(ReserveData storage _self) internal view returns(uint256){
        return LPlibrary.calculateLinearInterest(_self.currentLiquidityRate, _self.lastUpdateTimestamp).
                    rayMul(_self.cumulatedLiquidityIndex);
    }
    

}