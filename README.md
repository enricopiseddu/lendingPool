# A high-level implementation of Aave's some features

## 1. Introduction and goal
[Aave](https://github.com/aave/aave-protocol) is a protocol of Decentralized Finance (DeFi) based on the Lending Pool (LP) concept. LPs are “virtual places” where users can deposit and borrow (paying interests) different assets sending specific transactions to a smart contract that handles them. In general, the “deposit action” has no particular constraints while the “borrow action” is subject to some requirements: the most important is that the borrower must deposit a certain amount of collateral to cover his borrowing.

Although Aave provides a wide range of functions, the goal of this work is to summarize and focus on the main functions of Aave, that are “borrow” and “deposit”, highlining when they can be executed and how they modify the state of the lending pool and the users’ balances.


## 2. Tools used
This work is written in Solidity, and it is composed of four smart contracts:
- [LendingPool.sol](https://github.com/enricopiseddu/lendingPool/blob/main/LendingPool.sol), the main contract. It is the core of this work: it defines the borrow and deposit functions and other functions used by them
- [ERC20.sol](https://github.com/enricopiseddu/lendingPool/blob/main/ERC20.sol) is the contract that defines the ERC20 Token. Its interface is the [IERC20.sol](https://github.com/enricopiseddu/lendingPool/blob/main/IERC20.sol)
- [Ownable.sol](https://github.com/enricopiseddu/lendingPool/blob/main/Ownable.sol) is the contract from which LendingPool.sol inherits: it defines the “owner” of the lending pool that is the only address that can configure it.
- Finally, the library [WadRayMath.sol](https://github.com/enricopiseddu/lendingPool/blob/main/WadRayMath.sol) provides multiplications and divisions for wads and rays, respectively decimal numbers with 18 and 27 digits. Its usage is necessary because the language handles only integer numbers.

These smart contracts are developed thanks to [Remix IDE](https://remix.ethereum.org/) and [Metamask](https://metamask.io/).


## 3. Main differences between this work and the original implementation
In order to focus on the “deposit” and “borrow” actions, this work contains some changes that do not prejudice the meaning of Aave protocol. In this section we will see these differences.

**_Asset type_**
Aave handles both ERC20 tokens and Ethers, in fact users can deposit both of them. In this work, the main smart contract handles only ERC20 tokens: Ethers are used only to compare different ERC20 tokens and assign them a value. To do this, a particular address called “oracle” can set tokens’ prices. 

In Aave's implementation, this difference notices in the [deposit function](https://github.com/aave/aave-protocol/blob/master/contracts/lendingpool/LendingPool.sol#L299) that is a _payable_ function: this allows users to deposit Ethers to the Lending Pool, specifying as "address reserve" a particular address "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE" and as "amount" the exact amount contained in _msg.value_ (the amount of ETH sent by the _msg.sender_).

**_Variable and stable borrow rate_**
When using Aave, users can decide to open a borrow position with stable or variable rate. A stable rate ensures users expect (almost exactly) how much they will pay in interests. A variable rate is a rate that adjusts according the market’s offer and demand. In particular, it depends on the actual and the optimal utilization rate of the reserve and some constants. In this work, only variable borrow rate is used because the implementation of a stable borrow rate requires a continuous rebalancing process for each user.

**_Lending Pool configuration_**
In Aave it is possible to configure each reserve, in particular, each of them can be actived, freezed and enabled as collateral. An active and unfreezed reserve accepts deposits and borrows, while a freezed reserve accepts only repay and liquidation actions. These actions, in Aave, can be executed by a smart contract called “Lending Pool Configurator”. In this work, these actions are unnecessary because once a reserve is added, it is ready to accept deposits (also as collateral) and borrows actions.


## 4. Main features of this work

This section focuses mainly on actors and their actions towards the Lending Pool contract.
All formulas that calculate interest rates, health factor, the amount of collateral needed to open a new borrow position, etc, have been taken from the original Aave's implementation.

### 4.1 Actors

There are different actors involved in this work. All of them are represented by addresses and are:

- the “owner” of the Lending Pool: it is the address that deploys the contract. The owner can add a reserve (that is a contract that handles a particular ERC20 token) to the lending pool and initializes it, settings some parameters;

- the “price Oracle”, an address set by the “owner” that can modify ERC20 tokens’ price;

- users: they are addresses that mostly call the borrow and the deposit functions and query the Lending Pool in order to view its state.

### 4.2 Borrow function
The borrow function is summarized by the follow pseudocode:

```
borrow (address reserve, uint256 amountToBorrow){
	require(amountToBorrow > 0)
	require(LiquidityOfLendingPool >= amountToBorrow)
	Compute User Data //(total liquidity, collateral, borrows, LoanToValue, …, HF)
	require(HF > threshold) // threshold is tipically = 1
	Compute the fee (0.0025%) for the amountToBorrow 
	require(fee > 0)
	Compute needed collateral to cover the borrows
	require(user’s collateral >= collateral needed)
	Update the state of Lending Pool on borrow action
	Transfer to msg.sender the amountToBorrow required
}
```

The borrow function takes two parameters in input: the address of the reserve (that is the address of the contract handling the ERC20 token) from which the user (msg.sender) wants to borrow the "amountToBorrow" (the second parameter).

After checking that the amount to borrow is greater than zero and the specified reserve has enough liquidity (in terms of the number of tokens), the function computes the msg.sender's data, and in particular his health-factor (HF). The HF is a value calculated as the ratio of collateral deposited versus the amount borrowed: if HF<1, the loans of a user can be liquidated and so he can not borrow other assets.

After checking that user's HF is greater than 1, the function computes the fee, a fixed interest that is 0.0025% of the amount to borrow. As in Aave, the function checks that the fee is not zero.

According to the user's data calculated before, the function computes the minimum collateral needed to cover the user's borrows (including this amount to borrow). The collateral needed is a value depends on user's total borrows (including the current amount to borrow), his fees and his Loan-To-Value.

After checking that user has enough collateral, the function updates the state of the reserve (interest rates and timestamps). Finally, it transfers the number of _amountToBorrow_ tokens to the user, thanks to the Transfer method of the ERC20 contract.


### 4.3 Deposit function
The deposit function is summarized by the follow pseudocode:
```
deposit (address reserve, uint256 amountToDeposit, bool useAsCollateral){
	require(amount > 0)
	require(msg.sender allows the deposit) //allowance method of ERC20
	Transfer the amount to Lending Pool
	Mint an amount of aTokens
	Update the state of the reserve
	Eventually set user uses this reserve as collateral
}
```

The deposit function is more simple and short. It takes in input three parameters: the reserve in which the user (that is the msg.sender) wants to deposit, the amount to deposit and a boolean indicating if the user uses the reserve as collateral's deposit.

After checking that the amount to deposit is greater than zero, the function checks if the user allowed the Lending Pool to withdraw the amount, thanks to the "allowance" function of ERC20 contract.

Now, the Lending Pool calls the "TransferFrom" method of ERC20 contract, that transfers the amount from the msg.sender to the lending pool.
An amount of "amountToDeposit" of aTokens are minted for the user. These aTokens provide the user can redeem them in the future.

Finally, the function updates interest rates and timestamps for the reserve and keeps track in a data structure if the user wants to use the reserve as collateral.




### 4.4 Functions for computing users' data
All of these functions can be called by everyone
<hr />

```
function calculateUserGlobalData(address user) returns(uint256, uint256, uint256, uint256, uint256, uint256, uint256)
```

- Given a user, it returns 7 parameters: his total liquidity (deposited in all reserves), his total collateral, his total borrows, his total fees, his current Loan to value,  his liquidation threshold and its health factor.
<hr />

```
function calculateHealthFactorFromBalancesInternal(uint256 collateral, uint256 borrow, uint256 fee, uint256 liquidationThreshold)
```

- This function computes the health factor of a user. The health factor depends on user’s collateral, his borrow, his fee and his liquidation threshold.
<hr />

```
function getCompoundedBorrowBalance(address user, address reserve) returns(uint256)
```

- Given a user and a reserve, it returns the amount of user's tokens (borrowed+fee+interests) for the reserve. This amount is called "compounded borrow balance".
<hr />

```
function getUserBasicReserveData(address user, address reserve) returns(uint256, uint256, uint256, bool)
```

- Given a user and a reserve, it returns 4 parameteres: the amount of aTokens (minted), the compounded borrow balance, the fee and a boolean indicating if user uses the reserve as collateral 
<hr />


```
function getUserBorrowBalances(address user, address reserve) returns(uint256, uint256, uint256)
```

- Given a user and a reserve, it returns 3 parameters: the amount (borrowed+fee), the amount (borrowed+fee+interests) and the interests.
<hr />


### 4.5 Other functions called by users, the oracle and the owner
<hr />

```
function setPrice(address reserve, uint256 price)
```
- Only the oracle can set tokens’ prices.
<hr />

```
function addReserve(address reserve)
```

- Only the owner can add a reserve
<hr />

```
function calculateCollateralNeededInETH(address reserve, uint256 amount, uint256 fee, uint256 userBorrows, uint256 userFees, uint256 userLTV) returns(uint256)
```

- This function returns the collateral needed (in ETH) to cover the borrows (new amount to borrow + actual userBorrows). It can be called by everyone.
<hr />

```
function setUserUseReserveAsCollateral(address reserve, bool useAsCollateral)
```

- This function allows the user (the msg.sender) to set if he uses the reserve as collateral. This function can abort if the user’s collateral makes his health factor under a given threshold
<hr />

```
function balanceDecreaseAllowed(address reserve, address user, uint256 amount) returns(bool)
```

- This function returns true if an eventual decrease of a user’s collateral is allowed. It can be called by everyone.
<hr />


### 4.6 Functions for interests and interest rates calculus.
In general, interests for a single borrow depend on the time passing, on the amount borrowed and on the interest rate.

The interest rate for a reserve depends on:
- the utilization rate, defined as the ratio between the total borrows and the available liquidity
- the optimal utilization rate, set to 80% for all reserves.

Both Aave and this work compute time as difference between block timestamps.

The follow functions provide the interests and interest rate calculus:
```
function updateIndexes(address reserve)
function calculateLinearInterest(uint256 rate, uint256 lastUpdateTimestamp) return(uint256)
function calculateCompoundedInterest(uint256 rate, uint256 lastUpdateTimestamp) return(uint256)
function calculateInterestRates(uint256 availableLiquidity, uint256 totalBorrows) return(uint256 currentLiquidityRate, uint256 currentVariableBorrowRate)
```
