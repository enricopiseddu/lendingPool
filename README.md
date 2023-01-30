# A high-level implementation of Aave's some features

## Introduction and goal
Aave is a protocol of Decentralized Finance (DeFi) based on the Lending Pool (LP) concept. LPs are “virtual places” where users can deposit and borrow (paying interests) different assets sending specific transactions to a smart contract that handles them. In general, the “deposit action” has no particular constraints while the “borrow action” is subject to some requirements: the most important is that the borrower must deposit a certain amount of collateral to cover his borrowing.

Although Aave provides a wide range of functions, the goal of this work is to summarize and focus on the main functions of Aave, that are “borrow” and “deposit”, highlining when they can be executed and how they modify the state of the lending pool and the users’ balances.


## Tools used
This work is written in Solidity, and it is composed of four smart contracts:
- LendingPool.sol, the main contract. It is the core of this work: it defines the borrow and deposit functions and other functions used by them
- ERC20.sol is the contract that defines the ERC20 Token. Its interface is the IERC20.sol
- Ownable.sol is the contract from which LendingPool.sol inherits: it defines the “owner” of the lending pool that is the only address that can configure it.
- Finally, the library “WadRayMath.sol” provides multiplications and divisions for wads and rays, respectively decimal numbers with 18 and 27 digits. Its usage is necessary because the language handles only integer numbers.

These smart contracts are developed thanks to Remix IDE and Metamask.
