pragma solidity 0.4.26;

import "./Owned.sol";
import "./SafeMath.sol";
import "../converter/interfaces/ILiquidityPoolV1Converter.sol";

/**
 * @dev Provides the off-chain rate between two tokens
 *
 * The oracle is used by liquidity v1 pool converter to store the Exponential Moving
 * Averages of two tokens for each block having trades once. It is stored at the beginning
 * of each block.
 * EMA = k * currentPrice + (1 - k) * lastCumulativePrice
 * Were k is the weight given to more recent prices compared to the older ones.
 */
contract Oracle is Owned {
	using SafeMath for uint256;

	uint256 public blockNumber;
	uint256 public timestamp;
	uint256 public ema0;
	uint256 public ema1;
	uint256 public lastCumulativePrice0;
	uint256 public lastCumulativePrice1;
	uint256 public k;

	address public liquidityPool;
	address private constant BTC_ADDRESS = address(0xc0829421C1d260BD3cB3E0F06cfE2D52db2cE315);

	event ObservationsUpdated(
		uint256 ema0,
		uint256 ema1,
		uint256 blockNumber,
		uint256 timestamp,
		uint256 lastCumulativePrice0,
		uint256 lastCumulativePrice1
	);

	event KValueUpdate(uint256 _k);

	// ensures that the values are written by pool contract
	modifier validPool() {
		require(msg.sender == liquidityPool, "ERR_INVALID_POOL_ADDRESS");
		_;
	}

	/**
	 * @dev Initializes liquidity pool address for Oracle
	 * @param _liquidityPool liquidity pool address
	 */
	constructor(address _liquidityPool) public {
		require(_liquidityPool != address(0), "ERR_ZERO_POOL_ADDRESS");
		liquidityPool = _liquidityPool;
	}

	/**
	 * @dev Used to set the value of k
	 * @param _k new value of k
	 */
	function setK(uint256 _k) public ownerOnly {
		require(_k != 0 && _k <= 10000, "ERR_INVALID_K_VALUE");
		k = _k;
		emit KValueUpdate(_k);
	}

	/**
	 * @dev Used to write new price observations
	 * only valid liquidity pool contract can call this function
	 * @param _price0 price of token0
	 * @param _price1 price of token1
	 */
	function write(uint256 _price0, uint256 _price1) external validPool {
		if (blockNumber == block.number) return;

		uint256 timeElapsed;
		if (timestamp == 0) {
			ema0 = _price0;
			ema1 = _price1;

			timeElapsed = 1;
		} else {
			ema0 = k.mul(_price0).add((10000 - k).mul(ema0)).div(10000);
			ema1 = k.mul(_price1).add((10000 - k).mul(ema1)).div(10000);

			timeElapsed = block.timestamp.sub(timestamp);
		}

		lastCumulativePrice0 = lastCumulativePrice0.add(_price0.mul(timeElapsed));
		lastCumulativePrice1 = lastCumulativePrice1.add(_price1.mul(timeElapsed));

		blockNumber = block.number;
		timestamp = block.timestamp;

		emit ObservationsUpdated(ema0, ema1, blockNumber, timestamp, lastCumulativePrice0, lastCumulativePrice1);
	}

	/**
	 * @dev used to read the latest observations recorded
	 * @return ema0
	 * @return ema1
	 * @return blockNumber
	 * @return timestamp
	 * @return lastCumulativePrice0
	 * @return lastCumulativePrice1
	 */
	function read()
		external
		view
		returns (
			uint256,
			uint256,
			uint256,
			uint256,
			uint256,
			uint256
		)
	{
		return (ema0, ema1, blockNumber, timestamp, lastCumulativePrice0, lastCumulativePrice1);
	}

	/**
	 * @dev returns the price of a reserve in base currency (assuming one of the reserves is always BTC)
	 * @return ema
	 */
	function latestAnswer() external view returns (uint256 answer) {
		if (ILiquidityPoolV1Converter(liquidityPool).reserveTokens(0) == BTC_ADDRESS) {
			answer = ema0;
		} else answer = ema1;
	}
}