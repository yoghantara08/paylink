// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

contract Paylink is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidAddress();
    error InvalidAmount();
    error InvalidDuration();
    error InsufficientBalance();
    error StreamNotFound();
    error StreamFinished();
    error Unauthorized();

    struct Stream {
        address from;
        address to;
        address token;
        uint256 depositAmount;
        uint256 amountPerSecond;
        uint256 startTime;
        uint256 endTime;
        uint256 remainingBalance;
        uint256 lastUpdate;
    }

    mapping(uint256 => Stream) public streams;
    uint256 public streamId;

    event StreamCreated(
        uint256 indexed streamId,
        address indexed from,
        address indexed to,
        address token,
        uint256 depositAmount,
        uint256 startTime,
        uint256 endTime
    );
    event StreamCancelled(
        uint256 indexed streamId,
        address indexed from,
        address indexed to,
        uint256 refundAmount
    );
    event Withdraw(
        uint256 indexed streamId,
        address indexed recipient,
        uint256 amount
    );

    modifier onlyValidAddress(address _address) {
        if (_address == address(0) || _address == address(this)) {
            revert InvalidAddress();
        }
        _;
    }

    // CREATE STREAM
    function createStream(
        address _to,
        uint256 _depositAmount,
        address _token,
        uint256 _duration
    )
        external
        onlyValidAddress(_to)
        onlyValidAddress(_token)
        returns (uint256)
    {
        if (_to == msg.sender) revert InvalidAddress();
        if (_depositAmount == 0) revert InvalidAmount();
        if (_duration == 0) revert InvalidDuration();

        IERC20(_token).safeTransferFrom(
            msg.sender,
            address(this),
            _depositAmount
        );

        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + _duration;
        uint256 ratePerSecond = _depositAmount / _duration;

        streamId++;
        streams[streamId] = Stream({
            from: msg.sender,
            to: _to,
            token: _token,
            depositAmount: _depositAmount,
            amountPerSecond: ratePerSecond,
            startTime: startTime,
            endTime: endTime,
            remainingBalance: _depositAmount,
            lastUpdate: startTime
        });

        emit StreamCreated(
            streamId,
            msg.sender,
            _to,
            _token,
            _depositAmount,
            startTime,
            endTime
        );
        return streamId;
    }

    // CALCULATE STREAMED AMOUNT
    function calculateStreamedAmount(
        uint256 _streamId
    ) public view returns (uint256) {
        Stream storage stream = streams[_streamId];

        if (stream.from == address(0)) revert StreamNotFound();
        if (block.timestamp < stream.startTime) return 0;
        if (block.timestamp >= stream.endTime) return stream.remainingBalance;

        uint256 timeElapsed = block.timestamp - stream.lastUpdate;
        uint256 amount = timeElapsed * stream.amountPerSecond;

        return
            amount > stream.remainingBalance ? stream.remainingBalance : amount;
    }

    // WITHDRAW
    function withdraw(uint256 _streamId) external nonReentrant {
        Stream storage stream = streams[_streamId];

        if (stream.from == address(0)) revert StreamNotFound();
        if (msg.sender != stream.to) revert Unauthorized();
        if (stream.remainingBalance == 0) revert StreamFinished();

        uint256 amount = calculateStreamedAmount(_streamId);
        if (amount == 0) revert InsufficientBalance();

        stream.remainingBalance -= amount;
        stream.lastUpdate = block.timestamp;

        IERC20(stream.token).safeTransfer(stream.to, amount);

        emit Withdraw(_streamId, stream.to, amount);
    }

    // CANCEL STREAM
    function cancelStream(uint256 _streamId) external nonReentrant {
        Stream storage stream = streams[_streamId];

        if (stream.from == address(0)) revert StreamNotFound();
        if (msg.sender != stream.from) revert Unauthorized();
        if (stream.remainingBalance == 0) revert StreamFinished();

        uint256 streamedAmount = calculateStreamedAmount(_streamId);
        uint256 refundAmount = stream.remainingBalance > streamedAmount
            ? stream.remainingBalance - streamedAmount
            : 0;

        stream.remainingBalance = 0;
        stream.lastUpdate = block.timestamp;

        if (streamedAmount > 0) {
            IERC20(stream.token).safeTransfer(stream.to, streamedAmount);
        }
        if (refundAmount > 0) {
            IERC20(stream.token).safeTransfer(stream.from, refundAmount);
        }

        emit StreamCancelled(_streamId, stream.from, stream.to, refundAmount);
    }
}
