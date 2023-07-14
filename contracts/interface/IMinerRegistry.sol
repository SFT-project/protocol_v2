// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IMinerRegistry {

    function getGroupCount() external view returns (uint);
    function getMinersByGroupId(uint groupId) external view returns (uint[] memory);
    function getRecipientsByGroupId(uint groupId) external view returns (uint[] memory);
    function getGroupTotalWeight(uint groupId) external view returns (uint);
    function getReceipientWeight(uint groupId, uint actorId) external view returns (uint);
    function validateMiner(uint groupId, uint actorId) external view returns (bool);
    function validateRecipient(uint groupId, uint actorId) external view returns (bool);
}