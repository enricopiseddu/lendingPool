// SPDX-License-Identifier: CC-BY-4.0

pragma solidity >=0.7.0 <0.9.0;

import "IFlashLoanReceiver.sol";
import "ERC20.sol";


contract FlashLoan{

    uint256 public constant FEE = 5; //in percentage

    function flashLoan(address _receiver, address _reserve, uint256 _amount) public{

            ERC20 reserve = ERC20(_reserve);

            // Get the avaiable liquidity before flash loan is performed
            uint256 liquidityBeforeFlashLoan = reserve.balanceOf(address(this));

            // Check if there is enough liquidity to satisfy the loan
            require( liquidityBeforeFlashLoan >= _amount, "Not enough liquidity for flash loan");

            // Compute the fee for the loan and check it is > 0
            uint256 feeRequired = _amount*FEE/100;
            require(feeRequired > 0, "The fee must be greater than zero");
        
            IFlashLoanReceiver receiver = IFlashLoanReceiver(_receiver);

            // Transfer the amount to the receiver
            reserve.transfer(address(receiver), _amount);

            // Execute the code of the receiver: it should return the amount borrowed + the fee
            receiver.executeOperation(_reserve, _amount, feeRequired);

            // Check if the loan is completely repaid
            uint256 liquidityAfterFlashLoan = reserve.balanceOf(address(this));
            require(liquidityAfterFlashLoan == (liquidityBeforeFlashLoan + feeRequired), "The amount returned is not consistent");

        }
}