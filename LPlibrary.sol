// SPDX-License-Identifier: CC-BY-4.0

/// @title The lending pool library
/// @author Enrico Piseddu

pragma solidity >=0.7.0 <0.9.0;

import "WadRayMath.sol";
import "ERC20.sol";
import "SafeMath.sol";

library LPlibrary{

    using SafeMath for uint256;
    using WadRayMath for uint256;
    
    struct ReserveData{
        address adr; //address of the reserve
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

    uint256 constant SECONDS_PER_YEAR = 60*60*24*365; //number of seconds per year

    //Utilization constants
    uint256 constant OPTIMAL_UTILIZATION_RATE = 0.8 * 1e27; //express in ray
    uint256 constant EXCESS_UTILIZATION_RATE = 0.2 * 1e27; //express in ray

    uint256 public constant LIQUIDATION_BONUS = 5; //express in percentage

    //Parameters for interest calculus
    uint256 constant baseVariableBorrowRate = 1e27;
    uint256 constant r_slope1 = 8e27; //used when the reserve is under-used
    uint256 constant r_slope2 = 200e27; //used when the reserve is over-used

    

    /**
    * @dev Update the interest rate of a reserve according the taken or added liquidity and update the timestamp 
    * @param _self the reserve object
    * @param _liquidityAdded the liquidity added to the reserve (example in a deposit action)
    * @param _liquidityTaken the liquidity taken from the reserve (example in a borrow action)
    **/
    function updateInterestRatesAndTimestamp(ReserveData storage _self, uint256 _liquidityAdded, uint256 _liquidityTaken) public{
        uint256 liquidityAvailable = ERC20(_self.adr).balanceOf(address(this));
        (uint256 newLiquidityRate, uint256 newVariableRate) = calculateInterestRates(liquidityAvailable.add(_liquidityAdded).sub(_liquidityTaken), _self.totalVariableBorrows);

        _self.currentLiquidityRate = newLiquidityRate;
        _self.variableBorrowRate = newVariableRate;
        _self.lastUpdateTimestamp = block.timestamp;
    }


    /**
    * @dev Calculate the interest rates according the new balance of a reserve and its borrows
    * @param _availableLiquidity the balance of tokens of a reserve owned by the lending pool contract
    * @param _totalBorrows the total amount of borrowed tokens
    * @return currentLiquidityRate the new liquidity rate of the reserve
    * @return currentVariableBorrowRate the new interest rate for the reserve
    **/
    function calculateInterestRates(uint256 _availableLiquidity, uint256 _totalBorrows) public pure 
                                                                        returns(uint256 currentLiquidityRate, 
                                                                                uint256 currentVariableBorrowRate){
                                                                                    
        uint256 utilizationRate = (_totalBorrows == 0 && _availableLiquidity == 0)
            ? 0
            : _totalBorrows.rayDiv(_availableLiquidity.add(_totalBorrows));

        //calculate the variable borrow rate according the utilization of the reserve
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


    /**
    * @dev Calculate the health factor of a user
    * @param collateralBalanceETH the amount of collateral deposited by the user
    * @param borrowBalanceETH the total borrows of the user
    * @param totalFeesETH the total fees of the user
    * @param liquidationThreshold the liquidation threshold of the user (given by a weighted average of LTs of the reserve
    *        in which the user has deposited collateral 
    * @return healthFactor the user's healt factor
    **/
    function calculateHealthFactorFromBalancesInternal(uint256 collateralBalanceETH,
                                                        uint256 borrowBalanceETH,
                                                        uint256 totalFeesETH,
                                                        uint256 liquidationThreshold
        ) public pure returns (uint256) {
            if (borrowBalanceETH == 0) return 2**256-1; // maximum health factor because of no borrows

            return
                (collateralBalanceETH.mul(liquidationThreshold).div(100)).wadDiv(
                    borrowBalanceETH.add(totalFeesETH)
                );
    }

    /**
    * @dev Calculate linear interest accrued in the time
    * @param _rate the interest rate
    * @param _lastUpdateTimestamp the last timestamp
    * @return linearInterest the amount of accrued interest in the time
    **/
    function calculateLinearInterest(uint256 _rate, uint256 _lastUpdateTimestamp)
        public
        view
        returns (uint256)
    {
        
        uint256 timeDifference = block.timestamp.sub(_lastUpdateTimestamp);

        uint256 timeDelta = timeDifference.wadToRay().rayDiv(SECONDS_PER_YEAR.wadToRay());

        return _rate.rayMul(timeDelta).add(WadRayMath.ray());
    }

    /**
    * @dev Calculate compounded interest in the time
    * @param _rate the interest rate
    * @param _lastUpdateTimestamp the last timestamp
    * @return compoundedInterest the amount of accrued interest in the time
    **/
    function calculateCompoundedInterest(uint256 _rate, uint256 _lastUpdateTimestamp)
        public
        view
        returns (uint256)
    {
        uint256 timeDifference = block.timestamp.sub(_lastUpdateTimestamp);

        uint256 ratePerSecond = _rate.div(SECONDS_PER_YEAR);

        return ratePerSecond.add(WadRayMath.ray()).rayPow(timeDifference);
    }

    /**
    * @dev Update the variable borrow rate and the liquidity rate of a reserve
    * @param _self the reserve object
    **/
    function updateIndexes(ReserveData storage _self) public{
        uint256 totalBorrowsReserve = _self.totalVariableBorrows;
        
        uint256 variableBorrowRate;

        ERC20 reserve = ERC20(_self.adr);

        uint256 totalLiquidity = reserve.balanceOf(address(this));
        uint256 utilizationRate = (totalLiquidity == 0) ? 
                                        0 : 
                                        (totalBorrowsReserve.wadDiv(totalLiquidity));


        //calculate the variable borrow rate according the utilization rate
        variableBorrowRate = (utilizationRate <= OPTIMAL_UTILIZATION_RATE) ? 
                                                            baseVariableBorrowRate.add(utilizationRate.rayDiv(OPTIMAL_UTILIZATION_RATE).rayMul(r_slope1)) :
                                                            baseVariableBorrowRate.add(r_slope1).add(r_slope2.rayMul( utilizationRate.sub(OPTIMAL_UTILIZATION_RATE).rayDiv(EXCESS_UTILIZATION_RATE) ));

        _self.variableBorrowRate = variableBorrowRate;

        uint256 currentLiquidityRate = variableBorrowRate.rayMul(utilizationRate);
        

        if(totalBorrowsReserve > 0){
            //update cumulated liquidity index
            uint256 cumulatedLiquidityInterest = calculateLinearInterest(currentLiquidityRate, _self.lastUpdateTimestamp);

            _self.cumulatedLiquidityIndex = cumulatedLiquidityInterest.rayMul(_self.cumulatedLiquidityIndex);


            //update cumulated variable borrow index
            uint256 cumulatedVariableBorrowInterest = calculateCompoundedInterest(variableBorrowRate, _self.lastUpdateTimestamp);

            _self.cumulatedVariableBorrowIndex = cumulatedVariableBorrowInterest.rayMul(_self.cumulatedVariableBorrowIndex);
        }
    }

    /**
    * @dev Calculate the amout of collateral to liquidate and the amount of principal currency to repay
    * @param _collateralPrice the collateral asset price
    * @param _principalPrice the pricipal asset price
    * @param _purchaseAmount the amount of collateral to buy
    * @param _userCollateralBalance the amount of collateral available of the user
    * @return collateralAmount the amount of collateral to send to the liquidator
    * @return principalNeeded the amount of principal asset that the liquidator must repay
    **/
    function calculateAvaiableCollateralToLiquidate(uint256 _collateralPrice, uint256 _principalPrice, uint256 _purchaseAmount, uint256 _userCollateralBalance) public pure 
        returns(uint256 collateralAmount, uint256 principalNeeded){

        //liquidator can obtain the respective amount of collateral (according the _purchaseAmount) + bonus 5%
        uint256 maxAmountCollateralToLiquidate= (_principalPrice
                    .mul(_purchaseAmount)
                    .div(_collateralPrice)
                    .mul(LIQUIDATION_BONUS) // 5%
                    .div(100))
                    .add(
                        _principalPrice
                        .mul(_purchaseAmount)
                        .div(_collateralPrice)
                    ); 

        // if the user under liquidation has not enough collateral, we recompute
        // the collateral amount to send to the liquidator and the principal amount needed
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

    /**
    * @dev Calculate the normalized income of a reserve
    * @param _self the reserve object
    * @return normalizedIncome the normalized income
    **/
    function getNormalizedIncome(ReserveData storage _self) public view returns(uint256){
        return calculateLinearInterest(_self.currentLiquidityRate, _self.lastUpdateTimestamp).
                    rayMul(_self.cumulatedLiquidityIndex);
    }
    

}