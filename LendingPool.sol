// SPDX-License-Identifier: CC-BY-4.0

/// @title A minimal implementation of Aave, focusing on borrow and deposit functions
/// @author Enrico Piseddu

pragma solidity >=0.7.0 <0.9.0;

import "WadRayMath.sol";
import "ERC20.sol";
import "Ownable.sol";
import "LPlibrary.sol";

// Lending Pool contract
contract LendingPool is Ownable{

    using WadRayMath for uint256;
    using SafeMath for uint256;
    using LPlibrary for LPlibrary.ReserveData;

    struct UserData{
        mapping(address=>bool) usesReserveAsCollateral;
        mapping(address=>uint256) numberOfTokensBorrowed;
        mapping(address=>uint256) fees; //fee of a borrow of a reserve
        mapping(address=>uint256) lastVariableBorrowCumulativeIndex; //from reserve to borrow cumulative index
        mapping(address=>uint256) lastUpdateTimestamp; //from reserve to timestamp
        uint256 currentLTV;
        uint256 healthFactor;
    }

    uint256 public numberOfReserves;
    mapping(address=>LPlibrary.ReserveData) public reserves;
    address[] public reserves_array;

    mapping(address=>mapping(address=>uint256)) usersIndexes; //used for incoming interests, user=>reserve=>index

    address public priceOracle;

    uint256 public constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18; // express in wad
    uint256 public constant ORIGINATION_FEE_PERCENTAGE = 0.0025 * 1e18; // express in wad, it is the fixed fee applied to all borrows (0.0025%)
    
    mapping(address=>mapping(address=>uint256)) public aTokens; //from user to reserve to numberOfmintedTokens
    mapping(address=>UserData) public users; 


    modifier onlyPriceOracle(){
        require(msg.sender == priceOracle, "");
        _;
    }

    constructor(address _priceOracle){
        priceOracle = _priceOracle;
    }

    function getNumberOfReserves() public view returns(uint256){
       return numberOfReserves;
    }

    function setPrice(address _reserve, uint256 _price) public onlyPriceOracle{
        require(_price > 0, "");
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

        require(!reserveAlreadyExists, "");

        reserves[_adr] = LPlibrary.ReserveData(_adr,10**27,10**27,0,0,0,0,0,1,0,75,95);
        reserves_array.push(_adr);
        numberOfReserves = numberOfReserves + 1;
        
    }


    function deposit(address _reserve, uint256 _amount, bool _useAsCollateral) public{
        
        ERC20 tokenToDeposit = ERC20(_reserve);

        require(_amount > 0, "");

        require(tokenToDeposit.allowance(msg.sender, address(this)) == _amount, "");
        
        tokenToDeposit.transferFrom(msg.sender, address(this), _amount);

        //update timestamp
        reserves[_reserve].lastUpdateTimestamp = block.timestamp; 

        //update ci and bvc and rates
        reserves[_reserve].updateIndexes();

        //eventually adds accrued interests 
        cumulateBalanceInternal(msg.sender, _reserve);

        aTokens[msg.sender][_reserve] += _amount;

        if (_useAsCollateral){
            users[msg.sender].usesReserveAsCollateral[_reserve] = true;
        }

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

        require(_amount > 0, "");

        require( tokenToBorrow.balanceOf(address(this)) >= _amount, "");
        
        (
            ,
            vars.userCollateralBalanceETH,
            vars.userBorrowBalanceETH,
            vars.userTotalFeesETH,
            vars.currentLtv,
            vars.currentLiquidationThreshold,
            vars.healthFactorUser
        ) = calculateUserGlobalData(msg.sender);

        require(vars.userCollateralBalanceETH > 0, "");

        require(
            vars.healthFactorUser >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
            ""
        );

        //calculate fees
        vars.borrowFee = _amount.wadMul(ORIGINATION_FEE_PERCENTAGE);
        
        require(vars.borrowFee > 0, "");
        
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
            ""
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

        healthFactor = LPlibrary.calculateHealthFactorFromBalancesInternal(
            totalCollateralBalanceETH,
            totalBorrowBalanceETH,
            totalFeesETH,
            currentLiquidationThreshold
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

        uint256 cumulatedInterest = LPlibrary.calculateCompoundedInterest(reserves[_reserve].variableBorrowRate, reserves[_reserve].lastUpdateTimestamp);

        cumulatedInterest = cumulatedInterest.rayMul(reserves[_reserve].cumulatedVariableBorrowIndex).rayDiv(users[_user].lastVariableBorrowCumulativeIndex[_reserve]);

        uint256 compoundedBalance = principalBorrowBalanceRay.rayMul(cumulatedInterest).rayToWad();

        return compoundedBalance;
        
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
        
        reserves[_reserve].updateIndexes();
        

        // increase total borrows variable for the reserve
        reserves[_reserve].totalVariableBorrows += balanceIncrease.add(_amountBorrowed);

        //update user state
        users[_user].lastVariableBorrowCumulativeIndex[_reserve] = reserves[_reserve].cumulatedVariableBorrowIndex;

        users[_user].numberOfTokensBorrowed[_reserve] += _amountBorrowed.add(_borrowFee);

        users[_user].fees[_reserve] += _borrowFee;
        
        users[_user].lastUpdateTimestamp[_reserve] = block.timestamp;

        //update interest rates and timestamp for the reserve
        reserves[_reserve].updateInterestRatesAndTimestamp(0, _amountBorrowed);
        
        

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


    // Given a reserve and a boolean, it allows the msg.sender to use or not a reserve as collateral
    function setuserUseReserveAsCollateral(address _reserve, bool _useAsCollateral) public{
        uint256 underlyingBalance = aTokens[msg.sender][_reserve];

        require(underlyingBalance > 0, "");

        //check if a decrease of collateral is allowed (i.e. health factor after this action must be > 1)
        require(balanceDecreaseAllowed(_reserve, msg.sender, underlyingBalance), "");

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

        uint256 healthFactorAfterDecrease = LPlibrary.calculateHealthFactorFromBalancesInternal(
            vars.collateralBalancefterDecrease,
            vars.borrowBalanceETH,
            vars.totalFeesETH,
            vars.liquidationThresholdAfterDecrease
        );

        return healthFactorAfterDecrease > HEALTH_FACTOR_LIQUIDATION_THRESHOLD;

    }



    function repay(address _reserve, uint256 _amountToRepay, address _userToRepay) public{

        ERC20 tokenToRepay = ERC20(_reserve);

        (, uint256 compoundedBalance, uint256 interests ) = getUserBorrowBalances(_reserve, _userToRepay);

        uint256 fee = users[_userToRepay].fees[_reserve];

        //check if user is not under liquidation
        ( ,,,,,, uint256 healthFactor) = calculateUserGlobalData(_userToRepay);
        require(healthFactor > HEALTH_FACTOR_LIQUIDATION_THRESHOLD, "");
        
        //check if user has pending borrows in the reserve
        require(compoundedBalance > 0, "");

        //only a complete repayment is allowed
        require(_amountToRepay == compoundedBalance, "");
        require(tokenToRepay.allowance(msg.sender, address(this)) == compoundedBalance, "");

        //update state on repay
        updateStateOnRepay(_reserve, _userToRepay, _amountToRepay, fee, interests);

        //transfer assets to LP reserve
        tokenToRepay.transferFrom(msg.sender, address(this), _amountToRepay);

    }


    function updateStateOnRepay(address _reserve, address _userToRepay, uint256 _amountToRepay, uint256 _fee, uint256 _interests) internal{
        //update reserve state
        reserves[_reserve].updateIndexes();
        reserves[_reserve].totalVariableBorrows -= (_amountToRepay - _fee - _interests); //subtract the amount borrowed
        reserves[_reserve].totalVariableBorrows += (_fee + _interests); //add fee and interests

        //update user state for the reserve: all values are 0 because the repayment is complete
        users[_userToRepay].numberOfTokensBorrowed[_reserve] = 0;
        users[_userToRepay].lastVariableBorrowCumulativeIndex[_reserve] = 0;
        users[_userToRepay].fees[_reserve] = 0;
        users[_userToRepay].lastUpdateTimestamp[_reserve] = 0;

         //update interest rates and timestamp for the reserve
        reserves[_reserve].updateInterestRatesAndTimestamp(_amountToRepay, 0);

    }



    function cumulateBalanceInternal(address _user, address _reserve) internal returns(uint256, uint256, uint256, uint256){
        uint256 aTokensPreviousBalance = aTokens[_user][_reserve];
        uint256 cumulatedBalance = balanceOfAtokens(_user, _reserve); //aTokens + interests accrued

        uint accruedInterests = cumulatedBalance - aTokensPreviousBalance;

        //mint interests of ATokens
        aTokens[_user][_reserve] += accruedInterests;

        //update user index
        usersIndexes[_user][_reserve] = reserves[_reserve].getNormalizedIncome();

        return (aTokensPreviousBalance, cumulatedBalance, accruedInterests, usersIndexes[_user][_reserve]);
    }

    //it returns the amount of aTokens + interests accrued
    function balanceOfAtokens(address _user, address _reserve) public view returns(uint256){
        uint256 currentBalance = aTokens[_user][_reserve];
        if (currentBalance == 0){ return 0;}
        
        return currentBalance.wadToRay().rayMul(reserves[_reserve].getNormalizedIncome()).rayDiv(usersIndexes[_user][_reserve]).rayToWad();
    }



    function redeemAllTokens(address _reserve) public{
        ERC20 tokenToRedeem = ERC20(_reserve);

        //msg.sender can redeem all his tokens + accrued interests
        (uint256 aTokensWithoutInterests, uint256 amountToRedeem, ,) = cumulateBalanceInternal(msg.sender, _reserve);

        require(amountToRedeem > 0, "");

        require(balanceDecreaseAllowed(_reserve, msg.sender, aTokensWithoutInterests), "");

        //burn all aTokens
        aTokens[msg.sender][_reserve] = 0;

        // reset user index
        usersIndexes[msg.sender][_reserve] = 0;

        //check reserve has enough liquidity to redeem
        require(tokenToRedeem.balanceOf(address(this)) >= amountToRedeem, "");

        updateStateOnRedeem(_reserve, amountToRedeem);

        // trasfer assets
        tokenToRedeem.transfer(msg.sender, amountToRedeem);
    }


    function updateStateOnRedeem(address _reserve, uint256 _amountToRedeem) internal{
        reserves[_reserve].updateIndexes();

        //update interest rates and timestamp for the reserve
        reserves[_reserve].updateInterestRatesAndTimestamp(0, _amountToRedeem);
        
    }

    struct LiquidationVars{
        uint256 healthFactor;
        uint256 collateralBalance;
        uint256 compoundedBorrowBalance;
        uint256 interests;
        uint256 maximumAmountToLiquidate;
        uint256 actualAmountToLiquidate;
        uint256 maximumCollateralToLiquidate;
        uint256 principalAmountNeeded;
        uint256 fee;
        uint256 liquidatedCollateralForFee;
        uint256 feeLiquidated;
    }

    function liquidation(address _collateral, address _reserveToRepay, address _userToLiquidate, uint256 _amountToRepay) public{
        
        LiquidationVars memory vars;
        ERC20 reserveCollateral = ERC20(_collateral);
        ERC20 reserveToRepay = ERC20(_reserveToRepay);

        //Check if user is under liquidation
        (,,,,,, vars.healthFactor) = calculateUserGlobalData(_userToLiquidate);
        require(vars.healthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD, "");

        //Check if user has deposited collateral
        vars.collateralBalance = aTokens[_userToLiquidate][_collateral];
        require(vars.collateralBalance>0, "");

        //Check if user uses _collateral as collateral
        require(users[_userToLiquidate].usesReserveAsCollateral[_collateral], "");

        //Check if user has an active borrow on _reserveToRepay
        (, vars.compoundedBorrowBalance, vars.interests) = getUserBorrowBalances(_reserveToRepay, _userToLiquidate);
        require(vars.compoundedBorrowBalance > 0, "User has not an active borrow in _reserveToRepay");

        //Compute the maximum amount that can be liquidated (50% of the borrow)
        vars.maximumAmountToLiquidate = vars.compoundedBorrowBalance.mul(50).div(100); 

        vars.actualAmountToLiquidate = (_amountToRepay > vars.maximumAmountToLiquidate) ? vars.maximumAmountToLiquidate : _amountToRepay;

        (vars.maximumCollateralToLiquidate, vars.principalAmountNeeded) = LPlibrary.calculateAvaiableCollateralToLiquidate(reserves[_collateral].price, reserves[_reserveToRepay].price, vars.actualAmountToLiquidate, vars.collateralBalance);

        vars.fee = users[_userToLiquidate].fees[_reserveToRepay];
        
        if (vars.fee > 0){
            (vars.liquidatedCollateralForFee, vars.feeLiquidated) = LPlibrary.calculateAvaiableCollateralToLiquidate(reserves[_collateral].price, reserves[_reserveToRepay].price, vars.fee, vars.collateralBalance.sub(vars.maximumCollateralToLiquidate));
        }

        if (vars.principalAmountNeeded < vars.actualAmountToLiquidate) {
            vars.actualAmountToLiquidate = vars.principalAmountNeeded;
        }

        // check if LP has enough liquidity to send to liquidator
        require(reserveCollateral.balanceOf(address(this)) > vars.maximumCollateralToLiquidate, "LP has not enough liquidity");

        //Update state on liquidation
        updateStateOnLiquidation(_reserveToRepay, _collateral, _userToLiquidate, vars.actualAmountToLiquidate, vars.maximumCollateralToLiquidate, vars.feeLiquidated,
            vars.liquidatedCollateralForFee, vars.interests);

        //Burn aTokens liquidated
        aTokens[_userToLiquidate][_collateral] -= vars.maximumCollateralToLiquidate;

        //Transfer to liquidator the amount of collateral purchased
        reserveCollateral.transfer(msg.sender, vars.maximumCollateralToLiquidate.add(vars.liquidatedCollateralForFee));

        //Transfer to LP the amount repaid by the liquidator: liquidator must allow in ERC20 method
        reserveToRepay.transferFrom(msg.sender, address(this), vars.actualAmountToLiquidate.add(vars.feeLiquidated));

    }


    function updateStateOnLiquidation(address _principalReserve, address _collateralReserve, address _userToLiquidate,
        uint256 _amountToLiquidate, uint256 _collateralToLiquidated, uint256 _feeLiquidated, uint256 _liquidatedCollateralForFee, uint256 _interests) internal{
        
        //update principal reserve
        reserves[_principalReserve].updateIndexes();
        reserves[_principalReserve].totalVariableBorrows += _interests; //add interests
        reserves[_principalReserve].totalVariableBorrows -= _amountToLiquidate; //subtract the amount liquidated

        //update collateral reserve
        reserves[_collateralReserve].updateIndexes();

        //update the user's state
        users[_userToLiquidate].numberOfTokensBorrowed[_principalReserve] += _interests; //add interests
        users[_userToLiquidate].numberOfTokensBorrowed[_principalReserve] -= _amountToLiquidate; //subtract the amount liquidated

        users[_userToLiquidate].lastVariableBorrowCumulativeIndex[_principalReserve] = reserves[_principalReserve].cumulatedVariableBorrowIndex;
        users[_userToLiquidate].fees[_principalReserve] -= _feeLiquidated;
        users[_userToLiquidate].lastUpdateTimestamp[_principalReserve] = block.timestamp;

        //update interest rate for principal reserve
        reserves[_principalReserve].updateInterestRatesAndTimestamp(_amountToLiquidate, 0);

        //update interest rate for collateral reserve
        reserves[_collateralReserve].updateInterestRatesAndTimestamp(0, _collateralToLiquidated.add(_liquidatedCollateralForFee));
    

    }
}