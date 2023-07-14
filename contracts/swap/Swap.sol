// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@zondax/filecoin-solidity/contracts/v0.8/types/CommonTypes.sol";
import "@zondax/filecoin-solidity/contracts/v0.8/SendAPI.sol";

import "../interface/ISFTToken.sol";
import "../interface/IMinerRegistry.sol";
import "../interface/ILendingPool.sol";

// support FIL and SFT exchange mutually
contract Swap is Ownable2StepUpgradeable, Pausable {
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    // wait queue
    struct WaitQueue {
        DoubleEndedQueue.Bytes32Deque idQueue; // the id queue
        DoubleEndedQueue.Bytes32Deque accountQueue; // the account wait queue
        DoubleEndedQueue.Bytes32Deque amountQueue; // the amount wait queue corresponding to the account wait queue
    }

    WaitQueue private userQueue; // normal user wait queue to get SFT
    WaitQueue private marketMakerQueue; // market maker waite queue to get SFT
    WaitQueue private filWaitQueue; // if market maker try using SFT to swap FIL out but the FIL balance is not enough, push into this wait queue
    EnumerableSet.AddressSet private _whiteList; // market maker white list

    uint constant public BASE_POINT = 10000;
    ISFTToken public sftToken;
    IMinerRegistry public minerRegistry;
    address public taker; // take FIL address
    address public oracle;
    uint public feePoint;
    uint public sftWaitQueueCounter = 0; // the sft waite queue counter
    uint public filWaitQueueCounter = 0; // the fil wait queue counter

    bool public isPriorityForNormalUser; // if true normal users (not in whitelist) are prioritized when using SFT to swap FIL 
    WaitQueue private normalUserFilWaitQueue; // add a new fil wait queue for normal users (not in whitelist)

    address public lendingPool; // lendingPool contract address
    

    event SwapSft(address user, uint filAmountIn, uint sftAmountOut);
    event SwapFil(address user, uint amount);
    event Recharge(address recharger, uint amount);
    event Enqueue(uint id, address account, uint amount);
    event Dequeue(uint id, address account, uint amount, uint feePoint, bool isFull);
    event EnqueueV1(uint id, address account, uint amount);
    event DequeueV1(uint id, address account, uint amount);
    event SetTaker(address oldTaker, address newTaker);
    event SetFeePoint(uint oldFeePoint, uint newFeePoint);
    event TakeTokens(address taker, address recipient, uint amount);
    event TokensRescued(address to, address token, uint256 amount);
    event SendByActorId(uint64 actorId, uint amount);
    event SetOracle(address oldOracle, address newOracle);
    
    function initialize(ISFTToken _sftToken, IMinerRegistry _minerRegistry, address _taker, uint _feePoint) external initializer {
        require(address(_sftToken) != address(0), "SFT token address cannot be zero");
        __Context_init_unchained();
        __Ownable_init_unchained();
        sftToken = _sftToken;
        minerRegistry = _minerRegistry;
        _setTaker(_taker);
        _setFeePoint(_feePoint);
    }

    function setLendingPool(address _lendingPool) external onlyOwner {
        require(lendingPool == address(0), "LENDING_POOL_ALREADY_SET");
        lendingPool = _lendingPool;
        IERC20(sftToken).approve(lendingPool, type(uint256).max);
    }

    function SetIsPriorityForNormalUser(bool flag) public onlyOwner {
        isPriorityForNormalUser = flag;
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function addWhiteList(address account) external onlyOwner {
        _whiteList.add(account);
    }

    function removeWhiteList(address account) external onlyOwner {
        _whiteList.remove(account);
    }

    function getWhiteList() external view returns(address[] memory) {
        return _whiteList.values();
    }

    function isInWhiteList(address account) public view returns (bool) {
        return _whiteList.contains(account);
    }

    function setTaker(address newTaker) external onlyOwner {
        _setTaker(newTaker);
    }

    function _setTaker(address _taker) private {
        emit SetTaker(taker, _taker);
        taker = _taker;
    }

    function setOracle(address newOracle) external onlyOwner {
        _setOracle(newOracle);
    }

    function _setOracle(address _oracle) private {
        emit SetOracle(oracle, _oracle);
        oracle = _oracle;
    }

    function setFeePoint(uint newFeePoint) external {
        require(address(msg.sender) == oracle, "only oracle can call");
        _setFeePoint(newFeePoint);
    }

    function _setFeePoint(uint _feePoint) private {
        require(_feePoint < BASE_POINT, "invalid fee point");
        emit SetFeePoint(feePoint, _feePoint);
        feePoint = _feePoint;
    }

    function getFilBalance() public view returns (uint) {
        return address(this).balance;
    }

    function getSftBalance() public view returns (uint) {
        return sftToken.balanceOf(address(this));
    }

    function isUserQueueEmpty() public view returns (bool) {
        return userQueue.idQueue.empty();
    }

    function isMarketMakerQueueEmpty() public view returns (bool) {
        return marketMakerQueue.idQueue.empty();
    }

    function isSftWaitQueueEmpty() public view returns (bool) {
        return userQueue.idQueue.empty() && marketMakerQueue.idQueue.empty();
    }

    function isNormalUserFilWaitQueuEmpty() public view returns (bool) {
        return normalUserFilWaitQueue.idQueue.empty();
    }

    function isMarketMakerFilWaitQueueEmpty() public view returns (bool) {
        return filWaitQueue.idQueue.empty();
    }

    function isFilWaitQueueEmpty() public view returns (bool) {
        return filWaitQueue.idQueue.empty() && normalUserFilWaitQueue.idQueue.empty();
    }

    function getSftAmountOut(uint filAmountIn) public view returns (uint) {
        return filAmountIn * (BASE_POINT - feePoint) / BASE_POINT;
    }

    function getFilAmountOut(uint sftAmountIn) public view returns (uint) {
        return sftAmountIn * BASE_POINT / (BASE_POINT - feePoint);
    }

    function isSftBalanceTooSmall() public view returns (bool) {
        return sftToken.balanceOf(address(this)) <= BASE_POINT;
    }

    function getUserQueueLength() public view returns (uint) {
        return userQueue.idQueue.length();
    }

    function getMarketMakerQueueLength() public view returns (uint) {
        return marketMakerQueue.idQueue.length();
    }

    function getNormalUserFilWaitQueueLength() public view returns (uint) {
        return normalUserFilWaitQueue.idQueue.length();
    }

    function getMarketMakerFilWaitQueueLength() public view returns (uint) {
        return filWaitQueue.idQueue.length();
    }

    function getUserQueueItem(uint index) public view returns (uint id, address account, uint amount) {
        id = uint256(userQueue.idQueue.at(index));
        account = address(uint160(uint256(userQueue.accountQueue.at(index))));
        amount = uint256(userQueue.amountQueue.at(index));
    }

    function getMarketMakerQueueItem(uint index) public view returns (uint id, address account, uint amount) {
        id = uint256(marketMakerQueue.idQueue.at(index));
        account = address(uint160(uint256(marketMakerQueue.accountQueue.at(index))));
        amount = uint256(marketMakerQueue.amountQueue.at(index));
    }

    function getMarketMakerFilWaitQueueItem(uint index) public view returns (uint id, address account, uint amount) {
        id = uint256(filWaitQueue.idQueue.at(index));
        account = address(uint160(uint256(filWaitQueue.accountQueue.at(index))));
        amount = uint256(filWaitQueue.amountQueue.at(index));
    } 

    function getNormalUserFilWaitQueueItem(uint index) public view returns (uint id, address account, uint amount) {
        id = uint256(normalUserFilWaitQueue.idQueue.at(index));
        account = address(uint160(uint256(normalUserFilWaitQueue.accountQueue.at(index))));
        amount = uint256(normalUserFilWaitQueue.amountQueue.at(index));
    } 

    function getUserQueue() public view returns (uint[] memory idList, address[] memory accountList, uint[] memory amountList) {
        uint userQueueLength = getUserQueueLength();
        idList = new uint[](userQueueLength);
        accountList = new address[](userQueueLength);
        amountList = new uint[](userQueueLength);
        for (uint i = 0; i < userQueue.idQueue.length(); i++) {
            (idList[i], accountList[i], amountList[i]) = getUserQueueItem(i);
        }
    }

    function getMarketMakerQueue() public view returns (uint[] memory idList, address[] memory accountList, uint[] memory amountList) {
        uint marketMakerQueueLength = getMarketMakerQueueLength();
        idList = new uint[](marketMakerQueueLength);
        accountList = new address[](marketMakerQueueLength);
        amountList = new uint[](marketMakerQueueLength);
        for (uint i = 0; i < marketMakerQueue.idQueue.length(); i++) {
            (idList[i], accountList[i], amountList[i]) = getMarketMakerQueueItem(i);
        }
    }

    function getNormalUserFilWaitQueue() public view returns (uint[] memory idList, address[] memory accountList, uint[] memory amountList) {
        uint queueLength = getNormalUserFilWaitQueueLength();
        idList = new uint[](queueLength);
        accountList = new address[](queueLength);
        amountList = new uint[](queueLength);
        for (uint i = 0; i < queueLength; i++) {
            (idList[i], accountList[i], amountList[i]) = getNormalUserFilWaitQueueItem(i);
        }
    }

    function getMarketMakerFilWaitQueue() public view returns (uint[] memory idList, address[] memory accountList, uint[] memory amountList) {
        uint queueLength = getMarketMakerFilWaitQueueLength();
        idList = new uint[](queueLength);
        accountList = new address[](queueLength);
        amountList = new uint[](queueLength);
        for (uint i = 0; i < queueLength; i++) {
            (idList[i], accountList[i], amountList[i]) = getMarketMakerFilWaitQueueItem(i);
        }
    }

    function getNextSftWaitQueue() internal view returns (WaitQueue storage) {
        if (isMarketMakerQueueEmpty()) {
            return userQueue;
        }
        if (isUserQueueEmpty()) {
            return marketMakerQueue;
        }
        (uint userQueueFirstId, , ) = getUserQueueItem(0);
        (uint marketMakerQueueFirstId, , ) = getMarketMakerQueueItem(0);
        return (userQueueFirstId < marketMakerQueueFirstId? userQueue : marketMakerQueue);
    }

    function getNextFilWaitQueue() internal view returns (WaitQueue storage) {
        if (isPriorityForNormalUser) {
            return !isNormalUserFilWaitQueuEmpty()? normalUserFilWaitQueue : filWaitQueue; 
        } else {
            if (isMarketMakerFilWaitQueueEmpty()) {
                return normalUserFilWaitQueue;
            }
            if (isNormalUserFilWaitQueuEmpty()) {
                return filWaitQueue;
            }
            (uint normalUserFilWaitQueueFirstId, , ) = getNormalUserFilWaitQueueItem(0);
            (uint marketMakerFilWaitQueueFirstId, , ) = getMarketMakerFilWaitQueueItem(0);
            return (normalUserFilWaitQueueFirstId < marketMakerFilWaitQueueFirstId? normalUserFilWaitQueue : filWaitQueue);
        } 
    }

    function getQueueItem(WaitQueue storage queue, uint index) internal view returns (uint id, address account, uint amount) {
        id = uint256(queue.idQueue.at(index));
        account = address(uint160(uint256(queue.accountQueue.at(index))));
        amount = uint256(queue.amountQueue.at(index));
    }
 

    /**
    * @dev use fil to swap sft back according to specific exchange rate.
    * if there is any FIL remaining, try to repay borrows from lending pool
    */
    function swapSft() external payable whenNotPaused() {
        uint256 amount = msg.value;
        _swapSft(amount);
        _repayLiquidity(amount);
        _liquidateFilWaitQueue();
    }

    // using FIL to exchage SFT as much as possible, get in the wating queue if SFT not enough
    function _swapSft(uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        // Market Maker enqueue directly
        if (isInWhiteList(address(msg.sender))) {
            _enqueue(marketMakerQueue, msg.sender, amount, false);
            return;
        }
        if (!isUserQueueEmpty()) {
            _enqueue(userQueue, msg.sender, amount, false);
            return;
        }
        uint sftAmountOut = getSftAmountOut(amount);
        uint currentSftBlance = getSftBalance();
        if (currentSftBlance >= sftAmountOut) {
            require(sftToken.transfer(address(msg.sender), sftAmountOut), "swapSft: sft token transfer failed");
            _emitEnQueueAndDequeueEvent(msg.sender, amount, false);
            emit SwapSft(msg.sender, amount, sftAmountOut);
        } else {
            _enqueue(userQueue, msg.sender, amount, false);
            if (!isSftBalanceTooSmall()) {
                uint filAmountIn = getFilAmountOut(currentSftBlance);
                // actualSftAmountOut <= currentSftBlance
                uint actualSftAmountOut = getSftAmountOut(filAmountIn);
                uint remainFilAmount = amount - filAmountIn;
                _updateFirstItemAmount(userQueue, remainFilAmount, false);
                require(sftToken.transfer(address(msg.sender), actualSftAmountOut), "swapSft: sft token transfer failed");
                emit SwapSft(msg.sender, filAmountIn, actualSftAmountOut);
            }
        }
    }

    // repay the FIL borrow from lending pool 
    function _repayLiquidity(uint filAmountIn) internal {
        uint256 repayAmount = _calculateRepayAmount(filAmountIn);
        if (repayAmount > 0) {
            ILendingPool(lendingPool).repayLiquidity{value: repayAmount}();
            _liquidateUserQueue();
        }
    }

    function getNormalUserFilWaitAmount() public view returns (uint256 totalWaitAmount) {
        uint256 queueLength = getNormalUserFilWaitQueueLength();
        if (queueLength == 0) {
            return 0;
        }
        for (uint256 i = 0; i < queueLength; i++) {
            (, , uint amount) = getNormalUserFilWaitQueueItem(i);
            totalWaitAmount += amount;
        }
    }

    function _calculateRepayAmount(uint filAmountIn) internal view returns (uint repayAmount) {

        uint debt = ILendingPool(lendingPool).getLiquidityDebts();
        if (debt == 0) {
            return 0;
        }
        uint lackOfLiquidity = ILendingPool(lendingPool).getLackOfLiquidity();
        
        if (filAmountIn <= lackOfLiquidity) {
            return filAmountIn;
        } else {
            uint256 totalWaitAmount = getNormalUserFilWaitAmount();
            return filAmountIn - lackOfLiquidity >= totalWaitAmount ? filAmountIn - totalWaitAmount : lackOfLiquidity;
        }
    }

   /**
    * @dev user use sft to swap fil back, according to the exchange rate 1:1,
    * try to borrow FIL from lending pool if FIL balance not enough
    * @param amount the sft amount to swap
    */
    function swapFil(uint amount) external whenNotPaused() {
        _swapFil(amount);
        _borrowLiquidty();
        _liquidateUserQueue();      
    }

    // using SFT to exchage FIL as much as possible, get in the wating queue if FIL not enough
    function _swapFil(uint amount) internal {
        require(sftToken.allowance(address(msg.sender), address(this)) >= amount, "swapFil: approve amount not enough");
        require(sftToken.balanceOf(address(msg.sender)) >= amount, "swapFil: sft balance not enough");
        require(sftToken.transferFrom(address(msg.sender), address(this), amount), "swapFil: sft token transfer failed");
        if (amount == 0) {
            return;
        }
        WaitQueue storage queue = isInWhiteList(msg.sender)? filWaitQueue: normalUserFilWaitQueue;
        if (!isFilWaitQueueEmpty()) {
            _enqueue(queue, msg.sender, amount, true);
            return;
        }
        uint currentFilBalance = getFilBalance();
        if (currentFilBalance >= amount) {
            _emitEnQueueAndDequeueEvent(msg.sender, amount, true);
            safeTransferFIL(address(msg.sender), amount);
            emit SwapFil(msg.sender, amount);
        } else {
            _enqueue(queue, msg.sender, amount, true);
            _updateFirstItemAmount(queue, amount - currentFilBalance, true);
            safeTransferFIL(address(msg.sender), currentFilBalance);
            emit SwapFil(msg.sender, currentFilBalance);
        }
    }

    // try to borrow FIL from lending pool to meet redeem needs
    function _borrowLiquidty() internal {
        if (!isNormalUserFilWaitQueuEmpty() && ILendingPool(lendingPool).getAvailableLiquidity() > 0) {
            uint borrowAmount;
            for (uint i = 0; i < getNormalUserFilWaitQueueLength(); i++) {
                (, , uint waitAmount) = getQueueItem(normalUserFilWaitQueue, i);
                borrowAmount += waitAmount;
            }
            ILendingPool(lendingPool).borrowLiquidity(borrowAmount);
            _liquidateFilWaitQueue();
        }
    }

    /**
    * @notice transfer SFT into this contract and liquidate wait queue
    * @param sftMintedAmount the SFT amount minted from Deposit contract
    */
    function recharge(uint sftMintedAmount) external {
        require(sftToken.allowance(address(msg.sender), address(this)) >= sftMintedAmount, "recharge: approve amount not enough");
        require(sftToken.balanceOf(address(msg.sender)) >= sftMintedAmount, "recharge: sft balance not enough");
        require(sftToken.transferFrom(address(msg.sender), address(this), sftMintedAmount), "recharge: sft token transfer failed");
        _liquidateSftWaitQueue(sftMintedAmount);
        emit Recharge(msg.sender, sftMintedAmount);
    }

    // take fil token to filecoin node earn mining reward
    function takeTokens(address recipient, uint amount) external {
        require(address(msg.sender) == taker, "only taker can call");
        require(getFilBalance() >= amount, "fil token balance not enough");
        safeTransferFIL(recipient, amount);
        emit TakeTokens(address(msg.sender), recipient, amount);
    }


    // liquate the wait queue when new sft token transfer in and `swapFil` method
    function _liquidateUserQueue() internal {
        while (!isUserQueueEmpty() && !isSftBalanceTooSmall()) {
            (, address account, uint filAmountIn) = getUserQueueItem(0);
            uint sftAmountOut = getSftAmountOut(filAmountIn);
            if (getSftBalance() >= sftAmountOut) {
                _dequeue(userQueue, false);
                require(sftToken.transfer(account, sftAmountOut), "recharge: sft token transfer failed");
            } else {
                uint _filAmountIn = getFilAmountOut(getSftBalance());
                uint actualSftAmountOut = getSftAmountOut(_filAmountIn);
                _updateFirstItemAmount(userQueue, filAmountIn - _filAmountIn, false);
                require(sftToken.transfer(account, actualSftAmountOut), "recharge: sft token transfer failed");
                break;
            }
        }
    }

    function  _liquidateSftWaitQueue(uint sftMintedAmount) internal {
        while (!isSftWaitQueueEmpty() && sftMintedAmount > BASE_POINT) {
            WaitQueue storage nextQueue = getNextSftWaitQueue();
            (, address account, uint filAmountIn) = getQueueItem(nextQueue, 0);
            uint sftAmountOut = getSftAmountOut(filAmountIn);
            if (sftMintedAmount >= sftAmountOut) {
                _dequeue(nextQueue, false);
                require(sftToken.transfer(account, sftAmountOut), "recharge: sft token transfer failed");
                sftMintedAmount -= sftAmountOut;
            } else {
                uint _filAmountIn = getFilAmountOut(sftMintedAmount);
                uint actualSftAmountOut = getSftAmountOut(_filAmountIn);
                _updateFirstItemAmount(nextQueue, filAmountIn - _filAmountIn, false);
                require(sftToken.transfer(account, actualSftAmountOut), "recharge: sft token transfer failed");
                break;
            }
        }
    }

    function _liquidateFilWaitQueue() internal {
        uint currentFilBalance = getFilBalance();
        while (!isFilWaitQueueEmpty() && currentFilBalance > 0) {
            WaitQueue storage nextQueue = getNextFilWaitQueue();
            (, address account, uint sftAmount) = getQueueItem(nextQueue, 0);
            if (currentFilBalance >= sftAmount) {
                _dequeue(nextQueue, true);
                safeTransferFIL(account, sftAmount);
            } else {
                _updateFirstItemAmount(nextQueue, sftAmount - currentFilBalance, true);
                safeTransferFIL(account, currentFilBalance);
                break;
            }
        }
    }

    // enqueue
    function _enqueue(WaitQueue storage queue, address account, uint amount, bool isFilWaitQueue) internal {
        if (isFilWaitQueue) {
            filWaitQueueCounter++;
            queue.idQueue.pushBack(bytes32(filWaitQueueCounter));
            emit EnqueueV1(filWaitQueueCounter, account, amount);
        } else {
            sftWaitQueueCounter++;
            queue.idQueue.pushBack(bytes32(sftWaitQueueCounter));
            emit Enqueue(sftWaitQueueCounter, account, amount);
        }
        queue.accountQueue.pushBack(bytes32(uint256(uint160(account))));
        queue.amountQueue.pushBack(bytes32(amount));  
    }

    // dequeue
    function _dequeue(WaitQueue storage queue, bool isFilWaitQueue) internal {
        uint256 id = uint256(queue.idQueue.popFront());
        address account = address(uint160(uint256(queue.accountQueue.popFront())));
        uint256 amount = uint256(queue.amountQueue.popFront());
        if (isFilWaitQueue) {
            emit DequeueV1(id, account, amount);
        } else {
            emit Dequeue(id, account, amount, feePoint, true);
        } 
    }

    function _updateFirstItemAmount(WaitQueue storage queue, uint256 newAmount, bool isFilWaitQueue) internal {
        uint256 oldAmount = uint256(queue.amountQueue.popFront());
        queue.amountQueue.pushFront(bytes32(newAmount));
        address account = address(uint160(uint256(queue.accountQueue.at(0))));
        uint256 id = uint256(queue.idQueue.at(0));
        if (isFilWaitQueue) {
            emit DequeueV1(id, account, oldAmount - newAmount);
        } else {
            emit Dequeue(id, account, oldAmount - newAmount, feePoint, false);
        }
    }

    function _emitEnQueueAndDequeueEvent(address account, uint amount, bool isFilWaitQueue) internal {
        if (isFilWaitQueue) {
            filWaitQueueCounter++;
            emit EnqueueV1(filWaitQueueCounter, account, amount);
            emit DequeueV1(filWaitQueueCounter, account, amount);
        } else {
            sftWaitQueueCounter++;
            emit Enqueue(sftWaitQueueCounter, account, amount);
            emit Dequeue(sftWaitQueueCounter, account, amount, feePoint, true);
        }  
    }

    function safeTransferFIL(address to, uint value) internal {
        (bool success,) = to.call{value: value}("");
        require(success, "transfer FIL failed");
    }

    function _msgSender() internal view override(Context, ContextUpgradeable) returns (address) {
      return Context._msgSender();
    }

    function _msgData() internal view override(Context, ContextUpgradeable) returns (bytes calldata) {
      return Context._msgData();
    }

    receive() external payable {}

    // recover wrong tokens
    function rescueTokens(
        address _to,
        address _token,
        uint256 _amount
    ) external onlyOwner {
        require(_to != address(0), "Cannot send to address(0)");
        require(_amount != 0, "Cannot rescue 0 tokens");
        IERC20 token = IERC20(_token);
        token.safeTransfer(_to, _amount);
        emit TokensRescued(_to, _token, _amount);
    }
}