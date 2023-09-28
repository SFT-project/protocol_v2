// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract Lottery is Ownable2Step {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    struct Activity {
        string name;
        address requiredToken;
        address rewardToken;
        uint256 rewardAmount;
        uint256 signUpAmount; // the required token amount to sign up
        uint256 winnerNumber; // the number of winners
        uint256 seed;
        uint256 counter;
        uint256 startAt;
        uint256 endAt;
        bool isActive;
        EnumerableSet.AddressSet signers;
        EnumerableSet.AddressSet luckyUsers;
        mapping (uint256 => address) countToUser;
        mapping (address => bool) isClaimed;
    }

    uint256 public activityNumber;
    mapping (uint256 => Activity) private activity;

    event SignUp(uint256 activityNum, address user, address requiredToken, uint256 signUpAmount, uint256 count);
    event DrawLottery(uint256 activityNum, uint256 seed, uint256 timestamp, uint256 conter, address[] luckUsers);
    event Claim(uint256 activityNum, address user, address rewardToken, uint256 rewardAmount);
    event EmergeClose(uint256 activityNum);
    event TokensRescued(address to, address token, uint256 amount);

    function newActivity(
        string memory _name, 
        address _requiredToken, 
        address _rewardToken, 
        uint256 _rewardAmount, 
        uint256 _signUpAmount, 
        uint256 _winnerNumber
        ) external onlyOwner {
        require(!activity[activityNumber].isActive, "Last activity has not ended");
        activityNumber++;
        Activity storage act = activity[activityNumber];
        act.name = _name;
        act.requiredToken = _requiredToken;
        act.rewardToken = _rewardToken;
        act.rewardAmount = _rewardAmount;
        act.signUpAmount = _signUpAmount;
        act.winnerNumber = _winnerNumber;
        act.startAt = block.timestamp;
        act.isActive = true;
    }


    function getActivityInfo(uint256 _activityNumber) public view returns (
        address reqiredToken,
        address rewardToken,
        uint256 rewardAmount,
        uint256 signUpAmount, 
        uint256 winnerNumber,
        uint256 seed,
        uint256 counter,
        uint256 startAt,
        uint256 endAt,
        bool isActive,
        address[] memory signers,
        address [] memory luckyUsers
    ) {
        Activity storage act = activity[_activityNumber];
        reqiredToken = act.requiredToken;
        rewardToken = act.rewardToken;
        rewardAmount = act.rewardAmount;
        signUpAmount = act.signUpAmount;
        winnerNumber = act.winnerNumber;
        seed = act.seed;
        counter = act.counter;
        startAt = act.startAt;
        endAt = act.endAt;
        isActive = act.isActive;
        signers = act.signers.values();
        luckyUsers = act.luckyUsers.values();
    }

    function getUserByCount(uint256 _activityNumber, uint256 _count) public view returns (address) {
        Activity storage act = activity[_activityNumber];
        return act.countToUser[_count];
    }

    function isSignUp(address _account) public view returns (bool) {
        return activity[activityNumber].signers.contains(_account);
    }

    function isWin(uint256 _activityNumber, address _account) public view returns (bool) {
        Activity storage act = activity[_activityNumber];
        return act.luckyUsers.contains(_account);
    }

    function isClaimed(uint256 _activityNumber, address _account) public view returns (bool) {
        Activity storage act = activity[_activityNumber];
        return act.isClaimed[_account];
    }

    function signUp() external {
        Activity storage act = activity[activityNumber];
        require(act.isActive, "Activity has ended yet");
        require(!isSignUp(address(msg.sender)), "Already sign up");
        require(IERC20(act.requiredToken).balanceOf(address(msg.sender)) >= act.signUpAmount, "Required toekn balance not enough");
        IERC20(act.requiredToken).safeTransferFrom(address(msg.sender), address(this), act.signUpAmount);
        act.signers.add(address(msg.sender));
        act.countToUser[act.counter] = address(msg.sender);
        emit SignUp(activityNumber, address(msg.sender), act.requiredToken, act.signUpAmount, act.counter);
        act.counter++;
    }

    function drawLottery(uint256 _seed) external onlyOwner {
        Activity storage act = activity[activityNumber];
        require(act.counter >= act.winnerNumber, "Insufficient number of participants ");
        act.seed = _seed;
        uint256 nextSeed = _seed;
        for (uint256 i = 0; i < act.winnerNumber; i++) {
            while (true) {
                (uint256 luckyNumber, bool success) = addLuckyUser(nextSeed);
                if (success) {
                    nextSeed = luckyNumber;
                    break;
                } else {
                    nextSeed++;
                }
            } 
        }
        returnAssets();
        act.isActive = false;
        act.endAt = block.timestamp;
        emit DrawLottery(activityNumber, _seed, block.timestamp, act.counter, act.luckyUsers.values());
    }

    function claim(uint256 _activityNumber) external {
        Activity storage act = activity[_activityNumber];
        require(act.luckyUsers.contains(address(msg.sender)), "Not win in this activity");
        require(!act.isClaimed[address(msg.sender)], "Already claimed the reward");
        require(IERC20(act.rewardToken).balanceOf(address(this)) >= act.rewardAmount, "Reward token balance not enough");
        act.isClaimed[address(msg.sender)] = true;
        IERC20(act.rewardToken).safeTransfer(address(msg.sender), act.rewardAmount);
        emit Claim(_activityNumber, msg.sender, act.rewardToken, act.rewardAmount);
    }

    function addLuckyUser(uint256 _seed) internal returns (uint256 luckyNumber, bool success) {
         luckyNumber = generateRandomNumer(_seed);
         success = activity[activityNumber].luckyUsers.add(activity[activityNumber].countToUser[luckyNumber]);
    }

    function generateRandomNumer(uint256 _seed) internal view returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_seed, block.timestamp))) % activity[activityNumber].counter;
    }

    function returnAssets() internal {
        for (uint256 i = 0; i < activity[activityNumber].signers.length(); i++) {
            IERC20(activity[activityNumber].requiredToken).safeTransfer(activity[activityNumber].signers.at(i), activity[activityNumber].signUpAmount);
        }
    }

    function emergeClose() external onlyOwner {
        Activity storage act = activity[activityNumber];
        require(act.isActive, "Activity has ended yet");
        returnAssets();
        act.endAt = block.timestamp;
        act.isActive = false;
        emit EmergeClose(activityNumber);
    }

    // rescue wrong tokens
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