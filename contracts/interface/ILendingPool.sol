// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface ILendingPool {

    function deposit() external payable;
    function withdraw(uint256 amount) external returns (uint256);
    function borrow(uint orderId, uint amount) external returns (uint256);
    function repay(uint256 orderId) external payable returns (uint256);
    function pledgeOrder(uint256 pid, uint256 index) external;
    function unpledgeOrder(uint256 orderId) external;
    function getUtilizationRate() external view returns (uint256);
    function getAvailableLiquidity() external view returns (uint256);
    function borrowLiquidity(uint256 amount) external returns (uint256);
    function repayLiquidity() external payable returns (uint256);
    function distributeReward(uint256 rewardAmount) external payable;
    function getLiquidityDebts() external view returns (uint256);
    function getLackOfLiquidity() external view returns (uint256);
    function afterRepayInterest(uint256 interestAmount) external;
    function rebaseOrderApplyBorrowAmount(uint256 orderId) external;
    function getBorrowInterestRate() external view returns (uint256);
    function getPledgedOrderInfo(uint256 orderId) external view returns (
        address user,
        uint256 pid,
        uint256 index,
        uint256 amount,
        uint256 stakeAt,
        uint256 lockPeriod,
        uint256 borrowAmount,
        uint256 applyBorrowAmount,
        bool isActive
    );
}