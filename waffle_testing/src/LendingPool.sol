// SPDX-License-Identifier: CC-BY-4.0

/// @title A minimal implementation of Aave, focusing on borrow and deposit functions
/// @author Enrico Piseddu

pragma solidity >=0.7.0 <0.9.0;

import "WadRayMath.sol";
import "ERC20.sol";
import "Ownable.sol";

// Lending Pool contract
contract LendingPool is Ownable{

    using WadRayMath for uint256;
    using SafeMath for uint256;

    struct UserData{
        mapping(address=>bool) usesReserveAsCollateral;
        mapping(address=>uint256) numberOfTokensBorrowed;
        mapping(address=>uint256) fees; //fee of a borrow of a reserve
        mapping(address=>uint256) lastVariableBorrowCumulativeIndex; //from reserve to borrow cumulative index
        mapping(address=>uint256) lastUpdateTimestamp; //from reserve to timestamp
        uint256 currentLTV;
        uint256 healthFactor;
    }

    struct ReserveData{
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

    uint256 public numberOfReserves;
    mapping(address=>ReserveData) public reserves;
    address[] public reserves_array;

    //parameter used for interest calculus: they must be initialized here and they are applied to all reserves
    uint256 baseVariableBorrowRate = 1e27;
    uint256 r_slope1 = 8e27;
    uint256 r_slope2 = 200e27;

    address public priceOracle;

    uint256 public constant OPTIMAL_UTILIZATION_RATE = 0.8 * 1e27; //express in ray
    uint256 public constant EXCESS_UTILIZATION_RATE = 0.2 * 1e27; //express in ray
    uint256 public constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18; // express in wad
    uint256 public constant ORIGINATION_FEE_PERCENTAGE = 0.0025 * 1e18; // express in wad, it is the fixed fee applied to all borrows (0.0025%)
    uint256 public constant SECONDS_PER_YEAR = 31536000;


    mapping(address=>mapping(address=>uint256)) public aTokens; //from user to reserve to numberOfmintedTokens
    mapping(address=>UserData) public users; 


    modifier onlyPriceOracle(){
        require(msg.sender == priceOracle, "Only Oracle can modify prices of tokens");
        _;
    }

    constructor(address _priceOracle){
        priceOracle = _priceOracle;
    }

    function getNumberOfReserves() public view returns(uint256){
       return numberOfReserves;
    }

    function setPrice(address _reserve, uint256 _price) public onlyPriceOracle{
        require(_price > 0, "Price of token can not be zero");
        reserves[_reserve].price = _price;
    }

    function addReserve(address _adr) public onlyOwner{
       
        //check if reserve already exists
        bool reserveAlreadyExists = false;
        for(uint256 r; r<numberOfReserves; r++){
            if(reserves_array[r] == _adr){
                reserveAlreadyExists = true;
            }
        }

        require(!reserveAlreadyExists, "Reserve already exists!");

        reserves[_adr] =  ReserveData(10**27,10**27,0,0,0,0,0,1,0,75,95);
        reserves_array.push(_adr);
        numberOfReserves = numberOfReserves + 1;
        
    }


    function deposit(address _reserve, uint256 _amount, bool _useAsCollateral) public{
        
        ERC20 tokenToDeposit = ERC20(_reserve);

        require(_amount > 0, "Amount to deposit must be greater than 0");

        require(tokenToDeposit.allowance(msg.sender, address(this)) == _amount, "Msg sender must allow the deposit of ERC20");
        
        tokenToDeposit.transferFrom(msg.sender, address(this), _amount);

        //update timestamp
        reserves[_reserve].lastUpdateTimestamp = block.timestamp; 

        //update ci and bvc and rates
        updateIndexes(_reserve);


        aTokens[msg.sender][_reserve] += _amount;

        if (_useAsCollateral){
            users[msg.sender].usesReserveAsCollateral[_reserve] = true;
        }

    }


    function updateIndexes(address _reserve) internal{
        uint256 totalBorrowsReserve = reserves[_reserve].totalVariableBorrows;
        
        uint256 variableBorrowRate;

        ERC20 reserve = ERC20(_reserve);
        uint256 totalLiquidity = reserve.balanceOf(address(this));
        uint256 utilizationRate = (totalLiquidity == 0) ? 0 : (totalBorrowsReserve.wadDiv(totalLiquidity));


        variableBorrowRate = (utilizationRate <= OPTIMAL_UTILIZATION_RATE) ? baseVariableBorrowRate.add(utilizationRate.rayDiv(OPTIMAL_UTILIZATION_RATE).rayMul(r_slope1)) :
                                                            baseVariableBorrowRate.add(r_slope1).add(r_slope2.rayMul( utilizationRate.sub(OPTIMAL_UTILIZATION_RATE).rayDiv(EXCESS_UTILIZATION_RATE) ));

        reserves[_reserve].variableBorrowRate = variableBorrowRate;

        uint256 currentLiquidityRate = variableBorrowRate.rayMul(utilizationRate);
        

        if(totalBorrowsReserve > 0){
            //update Ci
            uint256 cumulatedLiquidityInterest = calculateLinearInterest(currentLiquidityRate, reserves[_reserve].lastUpdateTimestamp);

            reserves[_reserve].cumulatedLiquidityIndex = cumulatedLiquidityInterest.rayMul(reserves[_reserve].cumulatedLiquidityIndex);


            //update Bvc
            uint256 cumulatedVariableBorrowInterest = calculateCompoundedInterest(variableBorrowRate, reserves[_reserve].lastUpdateTimestamp);

            reserves[_reserve].cumulatedVariableBorrowIndex = cumulatedVariableBorrowInterest.rayMul(reserves[_reserve].cumulatedVariableBorrowIndex);
        }
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
    

    struct BorrowLocalVars {
        uint256 currentLtv;
        uint256 currentLiquidationThreshold;
        uint256 borrowFee;
        uint256 amountOfCollateralNeededETH;
        uint256 userCollateralBalanceETH;
        uint256 userBorrowBalanceETH;
        uint256 userTotalFeesETH;
        uint256 reserveDecimals;
        uint256 healthFactorUser;
    }

    function borrow(address _reserve, uint256 _amount) public{
   
        BorrowLocalVars memory vars;

        ERC20 tokenToBorrow = ERC20(_reserve);

        require(_amount > 0, "Amount to borrow must be greater than 0");

        require( tokenToBorrow.balanceOf(address(this)) >= _amount, "Not enough liquidity for the borrow");
        
        (
            ,
            vars.userCollateralBalanceETH,
            vars.userBorrowBalanceETH,
            vars.userTotalFeesETH,
            vars.currentLtv,
            vars.currentLiquidationThreshold,
            vars.healthFactorUser
        ) = calculateUserGlobalData(msg.sender);

        require(vars.userCollateralBalanceETH > 0, "The collateral balance is 0");

        require(
            vars.healthFactorUser >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
            "The borrower can already be liquidated so he cannot borrow more"
        );

        //calculate fees
        vars.borrowFee = _amount.wadMul(ORIGINATION_FEE_PERCENTAGE);
        
        require(vars.borrowFee > 0, "The amount to borrow is too small");
        
        //calculate collateral needed
        vars.amountOfCollateralNeededETH = calculateCollateralNeededInETH(
            _reserve,
            _amount,
            vars.borrowFee,
            vars.userBorrowBalanceETH,
            vars.userTotalFeesETH,
            vars.currentLtv
        );
        
        require(
            vars.amountOfCollateralNeededETH <= vars.userCollateralBalanceETH,
            "There is not enough collateral to cover a new borrow"
        );
        
        //update state for borrow action
        updateStateOnBorrow(_reserve, msg.sender, _amount, vars.borrowFee);

        //transfer assets: direct transfer of ERC20
        tokenToBorrow.transfer(msg.sender, _amount);
    }

    struct UserGlobalDataLocalVars {
        uint256 reserveUnitPrice;
        uint256 tokenUnit;
        uint256 compoundedLiquidityBalance;
        uint256 compoundedBorrowBalance;
        uint256 baseLtv;
        uint256 liquidationThreshold;
        uint256 originationFee;
        bool userUsesReserveAsCollateral;
        address currentReserve;
    }


    // Given an user, it returns the total Liquidity deposited by the user in ETH, the total of his collateral in ETH, 
    // the total of his borrows in ETH, the total fees, the Loan to Value of the user, his liquidation threshold and his HF
    function calculateUserGlobalData(address _user) public view returns(uint256 totalLiquidityBalanceETH, //for the user
                                                                        uint256 totalCollateralBalanceETH,
                                                                        uint256 totalBorrowBalanceETH,
                                                                        uint256 totalFeesETH,
                                                                        uint256 currentLtv,
                                                                        uint256 currentLiquidationThreshold,
                                                                        uint256 healthFactor){
        UserGlobalDataLocalVars memory vars;

        
        // Data are computed for each reserve
        for(uint256 i=0; i<numberOfReserves;i++){
            vars.currentReserve = reserves_array[i];
            
            (
                vars.compoundedLiquidityBalance, //aTokens
                vars.compoundedBorrowBalance, //amount borrowed+fee+interests
                vars.originationFee,
                vars.userUsesReserveAsCollateral
            ) = getUserBasicReserveData(_user, vars.currentReserve);

            if (vars.compoundedLiquidityBalance == 0 && vars.compoundedBorrowBalance == 0) {
                continue; //compute data for the next reserve
            }

            vars.tokenUnit = 10 ** reserves[vars.currentReserve].decimals;
            vars.reserveUnitPrice = reserves[vars.currentReserve].price;
            vars.baseLtv = reserves[vars.currentReserve].baseLtvAsCollateral;
            vars.liquidationThreshold = reserves[vars.currentReserve].liquidationThreshold;

            if (vars.compoundedLiquidityBalance > 0) {
                uint256 liquidityBalanceETH = vars
                    .reserveUnitPrice
                    .mul(vars.compoundedLiquidityBalance)
                    .div(vars.tokenUnit);
                totalLiquidityBalanceETH = totalLiquidityBalanceETH.add(liquidityBalanceETH);

                if (vars.userUsesReserveAsCollateral) {
                    totalCollateralBalanceETH = totalCollateralBalanceETH.add(liquidityBalanceETH);
                    currentLtv = currentLtv.add(liquidityBalanceETH.mul(vars.baseLtv));
                    currentLiquidationThreshold = currentLiquidationThreshold.add(
                        liquidityBalanceETH.mul(vars.liquidationThreshold)
                    );
                }
            }

            if (vars.compoundedBorrowBalance > 0) {
                totalBorrowBalanceETH = totalBorrowBalanceETH.add(
                    vars.reserveUnitPrice.mul(vars.compoundedBorrowBalance).div(vars.tokenUnit)
                );
                totalFeesETH = totalFeesETH.add(
                    vars.originationFee.mul(vars.reserveUnitPrice).div(vars.tokenUnit)
                );
            }
        }

        currentLtv = totalCollateralBalanceETH > 0 ? currentLtv.div(totalCollateralBalanceETH) : 0;
        currentLiquidationThreshold = totalCollateralBalanceETH > 0
            ? currentLiquidationThreshold.div(totalCollateralBalanceETH)
            : 0;

        healthFactor = calculateHealthFactorFromBalancesInternal(
            totalCollateralBalanceETH,
            totalBorrowBalanceETH,
            totalFeesETH,
            currentLiquidationThreshold
        );


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


    // Given an user and a reserve, it returns the amounts of his aTokens, the amount borrowed+fee+interests, the fee and
    // if the user uses the reserve as collateral
    function getUserBasicReserveData(address _user, address _reserve) internal view returns(uint256, uint256, uint256, bool){
        uint256 underlyingBalance = aTokens[_user][_reserve];

        bool userUsesReserveAsCollateral = users[_user].usesReserveAsCollateral[_reserve];

        if(users[_user].numberOfTokensBorrowed[_reserve] == 0){
            return (underlyingBalance, 0,0, userUsesReserveAsCollateral);
        }

        uint256 compoundedBorrowBalance = getCompoundedBorrowBalance(_user, _reserve);

        return (underlyingBalance, compoundedBorrowBalance, users[_user].fees[_reserve], userUsesReserveAsCollateral);

    }


    // Given an user and a reserve, it returns the amount of token borrowed+interests+fee (it is called "compounded borrow balance")
    function getCompoundedBorrowBalance(address _user, address _reserve) internal view returns(uint256){
        if(users[_user].numberOfTokensBorrowed[_reserve]==0){ return 0;}

        uint256 principalBorrowBalanceRay = users[_user].numberOfTokensBorrowed[_reserve].wadToRay();

        uint256 cumulatedInterest = calculateCompoundedInterest(reserves[_reserve].variableBorrowRate, reserves[_reserve].lastUpdateTimestamp);

        cumulatedInterest = cumulatedInterest.rayMul(reserves[_reserve].cumulatedVariableBorrowIndex).rayDiv(users[_user].lastVariableBorrowCumulativeIndex[_reserve]);

        uint256 compoundedBalance = principalBorrowBalanceRay.rayMul(cumulatedInterest).rayToWad();

        return compoundedBalance;
        
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



    // This function computes the collateral needed (in ETH) to cover a new borrow position.
    // The _amount is the number of tokens of _reserve that the user want borrowing.
    // _fee is the fee of the _amount
    // The last 3 parameters refer to the actual status of the user
    function calculateCollateralNeededInETH(
        address _reserve,
        uint256 _amount,
        uint256 _fee,
        uint256 _userCurrentBorrowBalanceETH,
        uint256 _userCurrentFeesETH,
        uint256 _userCurrentLtv
    ) public view returns (uint256) {
        uint256 reserveDecimals = reserves[_reserve].decimals;

        uint256 priceToken = reserves[_reserve].price;

        uint256 requestedBorrowAmountETH = priceToken
            .mul(_amount.add(_fee))
            .div(10 ** reserveDecimals); //price is in ether

        //add the current already borrowed amount to the amount requested to calculate the total collateral needed.
        uint256 collateralNeededInETH = _userCurrentBorrowBalanceETH
            .add(_userCurrentFeesETH)
            .add(requestedBorrowAmountETH)
            .mul(100)
            .div(_userCurrentLtv); //LTV is calculated in percentage

        return collateralNeededInETH;

    }


    function updateStateOnBorrow(address _reserve, address _user, uint256 _amountBorrowed, uint256 _borrowFee) internal{
        (, , uint256 balanceIncrease) = getUserBorrowBalances(_reserve, _user);
        
        updateIndexes(_reserve);
        

        // increase total borrows variable for the reserve
        reserves[_reserve].totalVariableBorrows += balanceIncrease.add(_amountBorrowed);

        //update user state
        users[_user].lastVariableBorrowCumulativeIndex[_reserve] = reserves[_reserve].cumulatedVariableBorrowIndex;

        users[_user].numberOfTokensBorrowed[_reserve] += _amountBorrowed.add(_borrowFee);

        users[_user].fees[_reserve] += _borrowFee;
        
        users[_user].lastUpdateTimestamp[_reserve] = block.timestamp;

     

        //update interest rates and timestamp for the reserve
        uint256 availableLiquidity = ERC20(_reserve).balanceOf(address(this));
        (uint256 newLiquidityRate, uint256 newVariableRate) = calculateInterestRates(availableLiquidity.sub(_amountBorrowed), reserves[_reserve].totalVariableBorrows);

        reserves[_reserve].currentLiquidityRate = newLiquidityRate;
        reserves[_reserve].variableBorrowRate = newVariableRate;
        reserves[_reserve].lastUpdateTimestamp = block.timestamp;
        

    }


    // Given an user and a reserve, it returns the (amountBorrowed+fee), (amountBorrowed+fee+interests), (interests)
    function getUserBorrowBalances(address _reserve, address _user)
        public
        view
        returns (uint256, uint256, uint256)
    {
        uint256 principalBorrowBalance = users[_user].numberOfTokensBorrowed[_reserve];

        if (principalBorrowBalance == 0) {
            return (0, 0, 0);
        }

        
        uint256 compoundedBalance = getCompoundedBorrowBalance(_user, _reserve);
        
        return (principalBorrowBalance, compoundedBalance, compoundedBalance.sub(principalBorrowBalance));
    }


    function calculateInterestRates(uint256 _availableLiquidity, uint256 _totalBorrows) public view 
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


    // Given a reserve and a boolean, it allows the msg.sender to use or not a reserve as collateral
    function setuserUseReserveAsCollateral(address _reserve, bool _useAsCollateral) public{
        uint256 underlyingBalance = aTokens[msg.sender][_reserve];

        require(underlyingBalance > 0, "User can not set the use of collateral because does not have any liqidity deposited in this reserve");

        //check if a decrease of collateral is allowed (i.e. health factor after this action must be > 1)
        require(balanceDecreaseAllowed(_reserve, msg.sender, underlyingBalance), "User can not set this reserve as collateral because this brings his health factor < 1");

        users[msg.sender].usesReserveAsCollateral[_reserve] = _useAsCollateral;

        
    }


    struct balanceDecreaseAllowedLocalVars {
        uint256 decimals;
        uint256 collateralBalanceETH;
        uint256 borrowBalanceETH;
        uint256 totalFeesETH;
        uint256 currentLiquidationThreshold;
        uint256 reserveLiquidationThreshold;
        uint256 amountToDecreaseETH;
        uint256 collateralBalancefterDecrease;
        uint256 liquidationThresholdAfterDecrease;
        uint256 healthFactorAfterDecrease;
        //bool reserveUsageAsCollateralEnabled;
    }



    // It checks if a decrease of collateral of a user is allowed
    function balanceDecreaseAllowed(address _reserve, address _user, uint256 _amount)
        public
        view
        returns (bool)
    {
        
        balanceDecreaseAllowedLocalVars memory vars;

        
        vars.decimals = reserves[_reserve].decimals;
        vars.reserveLiquidationThreshold = reserves[_reserve].liquidationThreshold; 
        //vars.reserveUsageAsCollateralEnabled


        if (
            !users[_user].usesReserveAsCollateral[_reserve]
        ) {
            return true; //beacuse the reserve is not used as collateral
        }

        (
            ,
            vars.collateralBalanceETH,
            vars.borrowBalanceETH,
            vars.totalFeesETH,
            ,
            vars.currentLiquidationThreshold,
        ) = calculateUserGlobalData(_user);

        if (vars.borrowBalanceETH == 0) {
            return true; //no borrows
        }

        vars.amountToDecreaseETH = reserves[_reserve].price.mul(_amount).div(
            10 ** vars.decimals
        );

        vars.collateralBalancefterDecrease = vars.collateralBalanceETH.sub(
            vars.amountToDecreaseETH
        );

        //if there is a borrow, there can't be 0 collateral
        if (vars.collateralBalancefterDecrease == 0) {
            return false;
        }

        vars.liquidationThresholdAfterDecrease = vars
            .collateralBalanceETH
            .mul(vars.currentLiquidationThreshold)
            .sub(vars.amountToDecreaseETH.mul(vars.reserveLiquidationThreshold))
            .div(vars.collateralBalancefterDecrease);

        uint256 healthFactorAfterDecrease = calculateHealthFactorFromBalancesInternal(
            vars.collateralBalancefterDecrease,
            vars.borrowBalanceETH,
            vars.totalFeesETH,
            vars.liquidationThresholdAfterDecrease
        );

        return healthFactorAfterDecrease > HEALTH_FACTOR_LIQUIDATION_THRESHOLD;

    }

}