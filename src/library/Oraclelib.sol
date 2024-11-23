// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AggregatorV3Interface} from 
    "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @dev Library for oracle functionality, including stale price checks.
 * @notice This library is used to verify the freshness of Chainlink oracle data.
 * If a price is stale, the function will revert, rendering the DSCEngine unusable.
 * This is by design to ensure that the protocol freezes when prices become unreliable.
 * @author 
 * If the Chainlink network becomes unavailable and funds are locked in the protocol,
 * this behavior is intentional for security purposes.
 */
library OracleLib {
    // Error for stale prices
    error OracleLib__StalePrice();

    // Constant timeout threshold for price staleness
    uint256 private constant TIMEOUT = 3 hours;

    /**
     * @notice Checks if the latest data from the Chainlink oracle is stale.
     * @param priceFeed The Chainlink AggregatorV3Interface instance.
     * @return roundId The round ID of the price data.
     * @return answer The price returned by the oracle.
     * @return startedAt The timestamp when the round started.
     * @return updatedAt The timestamp of the latest update.
     * @return answeredInRound The round ID in which the answer was computed.
     */
    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        // Fetch the latest round data from the price feed
        (roundId, answer, startedAt, updatedAt, answeredInRound) = priceFeed.latestRoundData();

        // Check if the price data is stale
        uint256 secondsSinceLastUpdate = block.timestamp - updatedAt;
        if (secondsSinceLastUpdate > TIMEOUT) {
            revert OracleLib__StalePrice();
        }

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
