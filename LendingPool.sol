// SPDX-License-Identifier: CC-BY-4.0

/// @title ProtoAave: a minimal implementation of Aave
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

    address public priceOracle; //the only address that can modify tokens' prices

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

    /**
    * @dev Get the number of the reserves holded by the lending pool
    * @return numberOfReserves the number of the reserves in the lending pool
    **/
    function getNumberOfReserves() public view returns(uint256){
       return numberOfReserves;
    }


    /**
    * @dev Set the price (in ethers) of a particular token holded in the reserve _reserve
    * Only the priceOracle address can modify prices
    * @param _reserve the reserve address
    * @param _price the new price of tokens
    **/
    function setPrice(address _reserve, uint256 _price) public onlyPriceOracle{

        require(_price > 0, "");
        reserves[_reserve].price = _price;
    }


    /**
    * @dev Add a new reserve to lending pool.
    * Only the owner can add a new reserve
    * @param _adr the reserve address
    **/
    function addReserve(address _adr) public onlyOwner{
       
        // Check if reserve already exists
        bool reserveAlreadyExists = false;
        for(uint256 r; r<numberOfReserves; r++){
            if(reserves_array[r] == _adr){
                reserveAlreadyExists = true;
            }
        }

        // Only a non-existing reserve can be added
        require(!reserveAlreadyExists, "");

        // We initialize a reserve with default parameters
        reserves[_adr] = LPlibrary.ReserveData(_adr,10**27,10**27,0,0,0,0,0,1,0,75,95);

        reserves_array.push(_adr);
        numberOfReserves = numberOfReserves + 1;
    }

    /**
    * @dev Deposit in the lending pool reserve
    * Anyone can deposit token in a reserve
    * @param _reserve the reserve address
    * @param _amount the _amount of tokens to deposit
    * @param _useAsCollateral set to "true" if the msg.sender wants use his tokens in the _reserve as collateral, false otherwise
    **/
    function deposit(address _reserve, uint256 _amount, bool _useAsCollateral) public{
        
        ERC20 tokenToDeposit = ERC20(_reserve);

        // Only an amount greater than zero can be deposited
        require(_amount > 0, "");

        // Check if msg.sender has allowed the lending pool to withdraw the amount to deposit
        require(tokenToDeposit.allowance(msg.sender, address(this)) == _amount, "");
        
        // Transfer to lending pool the amount to deposit
        tokenToDeposit.transferFrom(msg.sender, address(this), _amount);

        // Update the reserve's timestamp
        reserves[_reserve].lastUpdateTimestamp = block.timestamp; 

        // Update ci and bvc and rates
        reserves[_reserve].updateIndexes();

        // Eventually adds the accrued interests until now
        cumulateBalanceInternal(msg.sender, _reserve);

        // Mint and add the minted tokens for the msg.sender
        aTokens[msg.sender][_reserve] += _amount;

        // Set if msg.sender wants to use the reserve as collateral
        if (_useAsCollateral){
            users[msg.sender].usesReserveAsCollateral[_reserve] = true;
        }

    }

    // Struct used in the borrow function in order to avoid "stack too deep" error
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

    /**
    * @dev Borrow tokens from the lending pool reserve
    * @param _reserve the reserve address
    * @param _amount the _amount of tokens to borrow
    **/
    function borrow(address _reserve, uint256 _amount) public{
   
        BorrowLocalVars memory vars;

        ERC20 tokenToBorrow = ERC20(_reserve);

        // Only an amount greater than zero can be borrowed
        require(_amount > 0, "");

        // Check if the lending pool has enough liquidity for the borrower
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

        // The borrower must have some collateral
        require(vars.userCollateralBalanceETH > 0, "");

        // The borrower must not be under liquidation
        require(
            vars.healthFactorUser >= HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
            ""
        );

        // Calculate the fee, that is the the 0.0025% of the amount borrowed
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
        
        // Check if borrower has enough collateral to cover his loans
        require(
            vars.amountOfCollateralNeededETH <= vars.userCollateralBalanceETH,
            ""
        );
        
        // Update the state of the lending pool for this borrow action
        updateStateOnBorrow(_reserve, msg.sender, _amount, vars.borrowFee);

        // Trasfer to msg.sender the amount borrowed
        tokenToBorrow.transfer(msg.sender, _amount);
    }

    // Struct used in the calculateUserGlobalData(...) function in order to avoid "stack too deep" error
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
 
    /**
    * @dev Compute, for a user the total Liquidity deposited by the user in ETH, the total of his collateral in ETH, 
    * the total of his borrows in ETH, the total fees, the Loan to Value of the user, his liquidation threshold and his HF
    * @param _user the user address
    **/
    function calculateUserGlobalData(address _user) public view returns(uint256 totalLiquidityBalanceETH,
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


            // If the user has deposited in the reserve, we accumulate his total liquidity and eventually his collateral
            if (vars.compoundedLiquidityBalance > 0) {
                uint256 liquidityBalanceETH = vars
                    .reserveUnitPrice
                    .mul(vars.compoundedLiquidityBalance)
                    .div(vars.tokenUnit);
                totalLiquidityBalanceETH = totalLiquidityBalanceETH.add(liquidityBalanceETH);

                if (vars.userUsesReserveAsCollateral) {
                    // We accumulate his collateral
                    totalCollateralBalanceETH = totalCollateralBalanceETH.add(liquidityBalanceETH);

                    // We start computing his Loan to value (LTV) and Liquidation threshold(LT), defined ad weighted averages
                    // of LTVs and LTs of the reserves in which the user has deposited collateral
                    currentLtv = currentLtv.add(liquidityBalanceETH.mul(vars.baseLtv));
                    currentLiquidationThreshold = currentLiquidationThreshold.add(
                        liquidityBalanceETH.mul(vars.liquidationThreshold)
                    );
                }
            }
            
            // We accumulate the borrows and the fees
            if (vars.compoundedBorrowBalance > 0) {
                totalBorrowBalanceETH = totalBorrowBalanceETH.add(
                    vars.reserveUnitPrice.mul(vars.compoundedBorrowBalance).div(vars.tokenUnit)
                );
                totalFeesETH = totalFeesETH.add(
                    vars.originationFee.mul(vars.reserveUnitPrice).div(vars.tokenUnit)
                );
            }
        }

        // We end computing the LT and LTV of the user 
        currentLtv = totalCollateralBalanceETH > 0 ? currentLtv.div(totalCollateralBalanceETH) : 0;
        currentLiquidationThreshold = totalCollateralBalanceETH > 0
            ? currentLiquidationThreshold.div(totalCollateralBalanceETH)
            : 0;

        // Get the user health factor
        healthFactor = LPlibrary.calculateHealthFactorFromBalancesInternal(
            totalCollateralBalanceETH,
            totalBorrowBalanceETH,
            totalFeesETH,
            currentLiquidationThreshold
        );
    }

  
    /**
    * @dev Compute the user borrow data for a particular reserve
    * @param _user the user address
    * @param _reserve the reserve address
    * @return underlyingBalance the amounts of the user's aTokens (minted tokens)
    * @return compoundedBorrowBalance the amount borrowed+fee+interests for the reserve
    * @return fees the user total fees for his loans in the reserve
    * @return userUsesReserveAsCollateral true if user uses the reserve as collateral, false otherwise
    **/
    function getUserBasicReserveData(address _user, address _reserve) internal view returns(uint256, uint256, uint256, bool){
        uint256 underlyingBalance = aTokens[_user][_reserve];

        bool userUsesReserveAsCollateral = users[_user].usesReserveAsCollateral[_reserve];

        if(users[_user].numberOfTokensBorrowed[_reserve] == 0){
            return (underlyingBalance, 0,0, userUsesReserveAsCollateral);
        }

        uint256 compoundedBorrowBalance = getCompoundedBorrowBalance(_user, _reserve);

        return (underlyingBalance, compoundedBorrowBalance, users[_user].fees[_reserve], userUsesReserveAsCollateral);

    }


    /**
    * @dev Compute the user total debt for a particular reserve
    * @param _user the user address
    * @param _reserve the reserve address
    * @return compoundedBalance the amount of token borrowed+fee+interests 
    **/
    function getCompoundedBorrowBalance(address _user, address _reserve) internal view returns(uint256){
        if(users[_user].numberOfTokensBorrowed[_reserve]==0){ return 0;}

        uint256 principalBorrowBalanceRay = users[_user].numberOfTokensBorrowed[_reserve].wadToRay();

        uint256 cumulatedInterest = LPlibrary.calculateCompoundedInterest(reserves[_reserve].variableBorrowRate, reserves[_reserve].lastUpdateTimestamp);

        cumulatedInterest = cumulatedInterest.rayMul(reserves[_reserve].cumulatedVariableBorrowIndex).rayDiv(users[_user].lastVariableBorrowCumulativeIndex[_reserve]);

        uint256 compoundedBalance = principalBorrowBalanceRay.rayMul(cumulatedInterest).rayToWad();

        return compoundedBalance;
        
    }

    /**
    * @dev Compute the collateral needed to cover the loans of a user.
    * @param _reserve the reserve address from which someone wants to borrow
    * @param _amount the current amount to be borrowed
    * @param _fee the current fee for the new loan
    * @param _userCurrentBorrowBalanceETH the value (in ethers) of tokens borrowed including interests until now
    * @param _userCurrentFeesETH the total value (in ethers) of the fees for the loans until now
    * @param _userCurrentLtv the loan to value for the user
    * @return collateralNeededInETH the amount of collateral needed (in ethers) for cover the user's loans
    **/
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

        // we compute the amount to borrow in ethers
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


    /**
    * @dev Update the state of the lending pool and of the user in response to a borrow action.
    * @param _reserve the reserve address from which the user has borrowed
    * @param _user the borrower address
    * @param _amountBorrowed the amount borrowed
    * @param _borrowFee the fee for this loan
    **/
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


    /**
    * @dev Compute the borrow balances of a user for a reserve
    * @param _reserve the reserve address
    * @param _user the borrower address
    * @return principalBorrowBalance the amount of tokens borrowed + fee in the reserve
    * @return compoundedBalance the amount borrowed including fee and interests in the reserve
    * @return interests the interest accrued for the loan
    **/
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


    /**
    * @dev Allow a user to set a reserve as collateral. This function can abort if the loans of the user are not properly covered
    * @param _reserve the reserve address
    * @param _useAsCollateral true if the user wants to use the reserve as collateral, false otherwise
    **/
    function setuserUseReserveAsCollateral(address _reserve, bool _useAsCollateral) public{
        uint256 underlyingBalance = aTokens[msg.sender][_reserve];

        require(underlyingBalance > 0, "");

        //check if a decrease of collateral is allowed (i.e. health factor after this action must be > 1)
        require(balanceDecreaseAllowed(_reserve, msg.sender, underlyingBalance), "");

        users[msg.sender].usesReserveAsCollateral[_reserve] = _useAsCollateral;

        
    }

    // Struct used in the balanceDecreaseAllowed(...) function in order to avoid "stack too deep" error
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
    }

    /**
    * @dev Check if a decrease of user collateral is allowed
    * @param _reserve the reserve address
    * @param _user the user that requires a decrease of collateral
    * @param _amount the collateral decrease amount 
    * @return true if the user can set the reserve not as collateral, false otherwise
    **/
    function balanceDecreaseAllowed(address _reserve, address _user, uint256 _amount)
        public
        view
        returns (bool)
    {
        
        balanceDecreaseAllowedLocalVars memory vars;

        
        vars.decimals = reserves[_reserve].decimals;
        vars.reserveLiquidationThreshold = reserves[_reserve].liquidationThreshold; 

        // If the user is not using the reserve as collateral, no problems
        if ( !users[_user].usesReserveAsCollateral[_reserve]) {
            return true; 
        }

        (
            ,
            vars.collateralBalanceETH,
            vars.borrowBalanceETH,
            vars.totalFeesETH,
            ,
            vars.currentLiquidationThreshold,
        ) = calculateUserGlobalData(_user);

        // If the user has not loans, no problems
        if (vars.borrowBalanceETH == 0) {
            return true; //no borrows
        }

        // Compute the amount of decreased collateral and the new amount of collateral
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

        // Calculate the new liquidation threshold and the health factor
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


    /**
    * @dev Repay completely the debt (for a reserve) of a user
    * @param _reserve the reserve address 
    * @param _amountToRepay the amount to repay
    * @param _userToRepay the user to repay
    **/
    function repay(address _reserve, uint256 _amountToRepay, address _userToRepay) public{

        ERC20 tokenToRepay = ERC20(_reserve);

        (, uint256 compoundedBalance, uint256 interests ) = getUserBorrowBalances(_reserve, _userToRepay);

        uint256 fee = users[_userToRepay].fees[_reserve];

        //check if user has pending borrows in the reserve
        require(compoundedBalance > 0, "");

        //the amount to repay must be between the fee and the maximum debt of the user
        require(_amountToRepay <= compoundedBalance && _amountToRepay>=fee, "");
        require(tokenToRepay.allowance(msg.sender, address(this)) == _amountToRepay, "");

        uint256 amountToRepayMinusFee = _amountToRepay - fee;
        //update state on repay
        updateStateOnRepayPartial(_reserve, _userToRepay, amountToRepayMinusFee, fee, interests);

        //transfer assets to LP reserve
        tokenToRepay.transferFrom(msg.sender, address(this), _amountToRepay);

    }


    /**
    * @dev Update the state of a reserve in response to a repay action
    * @param _reserve the reserve address 
    * @param _userToRepay the user repaid
    * @param _amountToRepay the amount repaid
    * @param _fee the fee repaid
    * @param _interests the interest repaid 
    **/
    function updateStateOnRepayPartial(address _reserve, address _userToRepay, uint256 _amountToRepayMinusFee, uint256 _fee, uint256 _interests) internal{
        //update reserve state
        reserves[_reserve].updateIndexes();
        reserves[_reserve].totalVariableBorrows -= (_amountToRepayMinusFee + _fee); //subtract the amount repaid including fee
        reserves[_reserve].totalVariableBorrows += _interests; //add and interests

        //update user state for the reserve: all values are reseted because the repayment is complete
        users[_userToRepay].numberOfTokensBorrowed[_reserve] = users[_userToRepay].numberOfTokensBorrowed[_reserve] + _interests - _amountToRepayMinusFee + _fee;
        users[_userToRepay].lastVariableBorrowCumulativeIndex[_reserve] = reserves[_reserve].cumulatedVariableBorrowIndex;
        users[_userToRepay].fees[_reserve] -= _fee;
        users[_userToRepay].lastUpdateTimestamp[_reserve] = block.timestamp;

        //update interest rates and timestamp for the reserve
        reserves[_reserve].updateInterestRatesAndTimestamp(_amountToRepayMinusFee + _fee, 0);
    }

    
    
    /**
    * @dev Compute the new balance of aTokens of a user, for a particular reserve
    * @param _user the user address 
    * @param _reserve the reserve address
    * @return aTokensPreviousBalance amount of token before adding the actual accrued interest
    * @return cumulatedBalance the new balance of aTokens including the actual accrued interest
    * @return accruedInterests the interest accrued
    * @return index the index useful for interest calculus
    **/
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


    /**
    * @dev Compute the new balance of aTokens of a user (for a particular reserve), including the interest accrued
    * @param _user the user address 
    * @param _reserve the reserve address
    * @return cumulatedBalance the new balance of aTokens including the actual accrued interest
    **/
    function balanceOfAtokens(address _user, address _reserve) public view returns(uint256){
        
        uint256 currentBalance = aTokens[_user][_reserve];

        // if the user has zero aTokens, he has no accrued interests
        if (currentBalance == 0){ return 0;}
        
        return currentBalance.wadToRay().rayMul(reserves[_reserve].getNormalizedIncome()).rayDiv(usersIndexes[_user][_reserve]).rayToWad();
    }


    /**
    * @dev Allow the msg.sender to redeem all his aTokens, including the accrued interest
    * @param _reserve the reserve from which the msg.sender wants to redeem all his tokens
    **/
    function redeemAllTokens(address _reserve) public{
        ERC20 tokenToRedeem = ERC20(_reserve);

        // msg.sender can redeem all his tokens + accrued interests
        (uint256 aTokensWithoutInterests, uint256 amountToRedeem, ,) = cumulateBalanceInternal(msg.sender, _reserve);

        // The amount to redeem must be greater than zero
        require(amountToRedeem > 0, "");

        // Check if user can redeem his aTokens (after the redeem, his new HF must be over the threshold)
        require(balanceDecreaseAllowed(_reserve, msg.sender, aTokensWithoutInterests), "");

        //burn all his aTokens
        aTokens[msg.sender][_reserve] = 0;

        // reset user index
        usersIndexes[msg.sender][_reserve] = 0;

        //check reserve has enough liquidity to redeem
        require(tokenToRedeem.balanceOf(address(this)) >= amountToRedeem, "");

        updateStateOnRedeem(_reserve, amountToRedeem);

        // trasfer assets
        tokenToRedeem.transfer(msg.sender, amountToRedeem);
    }

    /**
    * @dev Update the state of a reserve in response to a redeem action, by updating indexes
    * and interest rates according the new liquidity
    * @param _reserve the reserve to be update
    * @param _amountToRedeem the amount redeemed
    **/
    function updateStateOnRedeem(address _reserve, uint256 _amountToRedeem) internal{
        reserves[_reserve].updateIndexes();

        //update interest rates and timestamp for the reserve
        reserves[_reserve].updateInterestRatesAndTimestamp(0, _amountToRedeem);
        
    }

    // Struct used in the liquidation(...) function in order to avoid "stack too deep" error
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


    /**
    * @dev Allow the msg.sender to liquidate a particular user, by repaying a part of his debt 
    * @param _collateral the reserve holding the collateral that must be buyed at a discount price
    * @param _reserveToRepay the reserve holding the assets the msg.sender must repay
    * @param _userToLiquidate the user under liquidation
    * @param _amountToRepay the amount that the liquidator wants to repay
    **/
    function liquidation(address _collateral, address _reserveToRepay, address _userToLiquidate, uint256 _amountToRepay) public{
        
        LiquidationVars memory vars;
        ERC20 reserveCollateral = ERC20(_collateral);
        ERC20 reserveToRepay = ERC20(_reserveToRepay);

        //Check if user is not under liquidation
        (,,,,,, vars.healthFactor) = calculateUserGlobalData(_userToLiquidate);
        require(vars.healthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD, "hf>1");

        //Check if user has deposited collateral
        vars.collateralBalance = aTokens[_userToLiquidate][_collateral];
        require(vars.collateralBalance>0, "coll<0");

        //Check if user uses the reserve _collateral as collateral
        require(users[_userToLiquidate].usesReserveAsCollateral[_collateral], "res not used as coll");

        //Check if user has an active borrow on _reserveToRepay
        (, vars.compoundedBorrowBalance, vars.interests) = getUserBorrowBalances(_reserveToRepay, _userToLiquidate);
        require(vars.compoundedBorrowBalance > 0, "User has not an active borrow in _reserveToRepay");

        //Compute the maximum amount that can be liquidated (50% of the borrow)
        vars.maximumAmountToLiquidate = vars.compoundedBorrowBalance.mul(50).div(100); 

        //If the amount that the liquidator wants to repay is greater than the maximum amount, we liquidate the maximum
        vars.actualAmountToLiquidate = (_amountToRepay > vars.maximumAmountToLiquidate) ? vars.maximumAmountToLiquidate : _amountToRepay;

        //Compute the collateral to liquidate
        (vars.maximumCollateralToLiquidate, vars.principalAmountNeeded) = LPlibrary.calculateAvaiableCollateralToLiquidate(reserves[_collateral].price, reserves[_reserveToRepay].price, vars.actualAmountToLiquidate, vars.collateralBalance);

        vars.fee = users[_userToLiquidate].fees[_reserveToRepay];
        
        //we liquidate also the fee
        if (vars.fee > 0){
            (vars.liquidatedCollateralForFee, vars.feeLiquidated) = LPlibrary.calculateAvaiableCollateralToLiquidate(reserves[_collateral].price, reserves[_reserveToRepay].price, vars.fee, vars.collateralBalance.sub(vars.maximumCollateralToLiquidate));
        }

        // we eventually adjust the amount to liquidate
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

    /**
    * @dev Update the state of the lending pool in response to a liquidation action
    * @param _principalReserve the reserve holding the assets the liquidator has repaid
    * @param _collateralReserve the reserve holding the collateral that has been sold at a discount price
    * @param _userToLiquidate the user under liquidation
    * @param _amountToLiquidate the amount liquidated
    * @param _collateralToLiquidated the amount of collateral sold to the liquidator
    * @param _feeLiquidated the amount of fee liquidated
    * @param _liquidatedCollateralForFee the amount of fee liquidated
    **/
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