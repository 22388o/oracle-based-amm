pragma solidity 0.5.16;

import "./openzeppelin/Address.sol";
import "./openzeppelin/SafeMath.sol";
import "./interfaces/IWrbtcERC20.sol";
import "./interfaces/ILiquidityPoolV1Converter.sol";
import "./interfaces/ILiquidityPoolV2Converter.sol";
import "./interfaces/ISmartToken.sol";
import "./interfaces/ISovrynSwapNetwork.sol";
import "./interfaces/IERC20Token.sol";

contract RBTCWrapperProxy{
    
    using Address for address;
    using SafeMath for uint256;

    bytes32 internal constant SOVRYNSWAP_FORMULA = "SovrynSwapFormula";

    address public wrbtcTokenAddress;
    address public sovAddress;
    address public sovrynSwapNetworkAddress;
    
    /**
     * @dev triggered after liquidity is added
     *
     * @param  _provider           liquidity provider
     * @param  _reserveAmount      provided reserve token amount
     * @param  _poolTokenAmount    minted pool token amount
     */
    event LiquidityAdded(
        address indexed _provider,
        uint256 indexed _reserveAmount,
        uint256 indexed _poolTokenAmount
    );


    event LiquidityAddedToV1(
        address indexed _provider,
        IERC20Token[] _reserveTokens, 
        uint256[] _reserveAmounts, 
        uint256 _poolTokenAmount
    );

    /**
     * @dev triggered after liquidity is removed
     *
     * @param  _provider           liquidity provider
     * @param  _reserveAmount      added reserve token amount
     * @param  _poolTokenAmount    burned pool token amount
     */
    event LiquidityRemoved(
        address indexed _provider,
        uint256 indexed _reserveAmount,
        uint256 indexed _poolTokenAmount
    );

 
    event LiquidityRemovedFromV1(
        address indexed _provider,
        address indexed _reserveToken,
        uint256 indexed _reserveAmount
    );

    /**
     * @dev triggered after liquidity is removed
     *
     * @param _beneficiary          account that will receive the conversion result or 0x0 to send the result to the sender account
     * @param _sourceTokenAmount    amount to convert from, in the source token
     * @param _targetTokenAmount    amount of tokens received from the conversion, in the target token
     * @param _path                 conversion path between two tokens in the network
     */
    event TokenConverted(
        address indexed _beneficiary,
        uint256 indexed _sourceTokenAmount,
        uint256 indexed _targetTokenAmount,
        IERC20Token[] _path
    );

    /**
     * @dev To check if ddress is contract address 
     */
    modifier checkAddress(address address_) {
        require(address_.isContract(), "The address is not a contract");
        _;
    }
    
    constructor(
        address _wrbtcTokenAddress, 
        address _sovAddress, 
        address _sovrynSwapNetworkAddress
    ) 
        public 
        checkAddress(_wrbtcTokenAddress) 
        checkAddress(_sovAddress) 
        checkAddress(_sovrynSwapNetworkAddress) 
    {
        wrbtcTokenAddress = _wrbtcTokenAddress;
        sovAddress = _sovAddress;
        sovrynSwapNetworkAddress = _sovrynSwapNetworkAddress;
    }

    function() external payable {
        require(wrbtcTokenAddress == msg.sender, "Only can receive rBTC from WRBTC contract");
    }

    /**
     * @dev  
     * The process:
     * 1.Accepts RBTC
     * 2.Sends RBTC to WRBTC contract in order to wrap RBTC to WRBTC
     * 3.Calls 'addLiquidity' on LiquidityPoolConverter contract
     * 4.Transfers pool tokens to user
     * 
     * @param _liquidityPoolConverterAddress    address of LiquidityPoolConverter contract
     * @param _amount                           amount of liquidity to add
     * @param _minReturn                        minimum return-amount of reserve tokens
     *
     * @return amount of pool tokens minted
     */
    function addLiquidity(
        address _liquidityPoolConverterAddress, 
        uint256 _amount, 
        uint256 _minReturn
    )  
        public
        payable
        checkAddress(_liquidityPoolConverterAddress)
        returns(uint256) 
    {
        require(_amount == msg.value, "The provided amount should be identical to msg.value");

        ILiquidityPoolV2Converter _liquidityPoolConverter = ILiquidityPoolV2Converter(_liquidityPoolConverterAddress);
        ISmartToken _poolToken = _liquidityPoolConverter.poolToken(IERC20Token(wrbtcTokenAddress));

        (bool successOfDeposit, ) = wrbtcTokenAddress.call.value(_amount)(abi.encodeWithSignature("deposit()"));
        require(successOfDeposit);

        bool successOfApprove = IWrbtcERC20(wrbtcTokenAddress).approve(_liquidityPoolConverterAddress, _amount);
        require(successOfApprove);

        uint256 poolTokenAmount = _liquidityPoolConverter.addLiquidity(IERC20Token(wrbtcTokenAddress), _amount, _minReturn);
        
        bool successOfTransfer = _poolToken.transfer(msg.sender, poolTokenAmount);
        require(successOfTransfer);

        emit LiquidityAdded(msg.sender, _amount, poolTokenAmount);

        return poolTokenAmount;
    }
    
    /**
     * @notice 
     * Before calling this function to remove liquidity, users need approve this contract to be able to spend or transfer their pool tokens
     *
     * @dev  
     * The process:     
     * 1.Transfers pool tokens to this contract
     * 2.Calls 'removeLiquidity' on LiquidityPoolConverter contract
     * 3.Calls 'withdraw' on WRBTC contract in order to unwrap WRBTC to RBTC
     * 4.Sneds RBTC to user
     * 
     * @param _liquidityPoolConverterAddress    address of LiquidityPoolConverter contract
     * @param _amount                           amount of pool tokens to burn
     * @param _minReturn                        minimum return-amount of reserve tokens
     * 
     * @return amount of liquidity removed also WRBTC unwrapped to RBTC
     */
    function removeLiquidity(
        address _liquidityPoolConverterAddress, 
        uint256 _amount, 
        uint256 _minReturn
    )   
        public 
        checkAddress(_liquidityPoolConverterAddress)
        returns(uint256) 
    {
        ILiquidityPoolV2Converter _liquidityPoolConverter = ILiquidityPoolV2Converter(_liquidityPoolConverterAddress);
        ISmartToken _poolToken = _liquidityPoolConverter.poolToken(IERC20Token(wrbtcTokenAddress));

        bool successOfTransferFrom = _poolToken.transferFrom(msg.sender, address(this), _amount);
        require(successOfTransferFrom);

        uint256 reserveAmount = _liquidityPoolConverter.removeLiquidity(_poolToken, _amount, _minReturn);
        
        IWrbtcERC20(wrbtcTokenAddress).withdraw(reserveAmount);
        
        msg.sender.transfer(reserveAmount);

        emit LiquidityRemoved(msg.sender, reserveAmount, _amount);

        return reserveAmount;
    }
    
    /**
     * @notice
     * Before calling this function to swap token to RBTC, users need approve this contract to be able to spend or transfer their tokens
     *
     * @param _path         conversion path between two tokens in the network
     * @param _amount       amount to convert from, in the source token
     * @param _minReturn    if the conversion results in an amount smaller than the minimum return - it is cancelled, must be greater than zero
     * 
     * @return amount of tokens received from the conversion
     */
    function convertByPath(
        IERC20Token[] memory _path,
        uint256 _amount, 
        uint256 _minReturn
    ) 
        public 
        payable
        returns(uint256) 
    {    
        ISovrynSwapNetwork _sovrynSwapNetwork =  ISovrynSwapNetwork(sovrynSwapNetworkAddress);
  
        if (msg.value != 0) {
            require(_path[0] == IERC20Token(wrbtcTokenAddress), "Value may only be sent for WRBTC transfers");
            require(_amount == msg.value, "The provided amount should be identical to msg.value");

            (bool successOfDeposit, ) = wrbtcTokenAddress.call.value(_amount)(abi.encodeWithSignature("deposit()"));
            require(successOfDeposit);

            bool successOfApprove = IWrbtcERC20(wrbtcTokenAddress).approve(sovrynSwapNetworkAddress, _amount);
            require(successOfApprove);

            uint256 _targetTokenAmount = _sovrynSwapNetwork.convertByPath(_path, _amount, _minReturn, msg.sender, address(0), 0);

            emit TokenConverted(msg.sender, _amount, _targetTokenAmount, _path);

            return _targetTokenAmount;
        }
        else {
            require(_path[_path.length-1] == IERC20Token(wrbtcTokenAddress), "It only could be swapped to WRBTC");
            
            IERC20Token _token = IERC20Token(_path[0]);

            bool successOfTransferFrom = _token.transferFrom(msg.sender, address(this), _amount);
            require(successOfTransferFrom);

            bool successOfApprove = _token.approve(sovrynSwapNetworkAddress, _amount);
            require(successOfApprove);
                 
            uint256 _targetTokenAmount = _sovrynSwapNetwork.convertByPath(_path, _amount, _minReturn, address(this), address(0), 0);

            IWrbtcERC20(wrbtcTokenAddress).withdraw(_targetTokenAmount);

            msg.sender.transfer(_targetTokenAmount);

            emit TokenConverted(msg.sender, _amount, _targetTokenAmount, _path);

            return _targetTokenAmount;
        }        
    }

    function addLiquidityToV1(
        address _liquidityPoolConverterAddress,
        IERC20Token[] memory _reserveTokens, 
        uint256[] memory _reserveAmounts, 
        uint256 _minReturn
    )  
        public
        payable
        checkAddress(_liquidityPoolConverterAddress)
        returns(uint256) 
    {
        uint256 lengthOfTokens = _reserveTokens.length;

        require(_reserveAmounts.length == lengthOfTokens.add(1), "The length of array is wrong");
        require(_reserveAmounts[lengthOfTokens] == msg.value, "The provided amount of RBTC should be identical to msg.value");

        bool successOfTransfer;
        bool successOfApprove;
        
        for (uint256 i = 0; i < lengthOfTokens; i++) {
            IERC20Token reserveToken = _reserveTokens[i];
            uint256 reserveAmount = _reserveAmounts[i];
            successOfTransfer = IERC20Token(reserveToken).transferFrom(msg.sender, address(this), reserveAmount);
            require(successOfTransfer, "Failed to transfer reserve token from user");
            successOfApprove = IERC20Token(reserveToken).approve(_liquidityPoolConverterAddress, reserveAmount);
            require(successOfApprove, "Failed to approve converter to transfer reserve token");
        }

        (bool successOfDeposit, ) = wrbtcTokenAddress.call.value(_reserveAmounts[lengthOfTokens])(abi.encodeWithSignature("deposit()"));
        require(successOfDeposit, "Failed to deposit RBTC to get WRBTC");
        _reserveTokens[lengthOfTokens] = IERC20Token(wrbtcTokenAddress);
        successOfApprove = IWrbtcERC20(wrbtcTokenAddress).approve(_liquidityPoolConverterAddress, _reserveAmounts[lengthOfTokens]);
        require(successOfApprove, "Failed to approve converter to transfer WRBTC");

        ILiquidityPoolV1Converter _liquidityPoolConverter = ILiquidityPoolV1Converter(_liquidityPoolConverterAddress);
        ISmartToken _poolToken = ISmartToken(address(_liquidityPoolConverter.token()));
        uint256 poolTokenAmountBefore = _poolToken.balanceOf(address(this));
        _liquidityPoolConverter.addLiquidity(_reserveTokens, _reserveAmounts, _minReturn);
        uint256 poolTokenAmountAfter = _poolToken.balanceOf(address(this));
        uint256 poolTokenAmount = poolTokenAmountAfter.sub(poolTokenAmountBefore);
        
        successOfTransfer = _poolToken.transfer(msg.sender, poolTokenAmount);
        require(successOfTransfer, "Failed to transfer pool token to user");

        emit LiquidityAddedToV1(msg.sender, _reserveTokens, _reserveAmounts, poolTokenAmount);

        return poolTokenAmount;
    }

    
    function removeLiquidityFromV1(
        address _liquidityPoolConverterAddress,
        uint256 _amount, 
        IERC20Token[] memory _reserveTokens, 
        uint256[] memory _reserveMinReturnAmounts
    )   
        public 
        checkAddress(_liquidityPoolConverterAddress)
    {
        require(_amount > 0, "The amount should larger than zero");

        ILiquidityPoolV1Converter _liquidityPoolConverter = ILiquidityPoolV1Converter(_liquidityPoolConverterAddress);
        ISmartToken _poolToken = ISmartToken(address(_liquidityPoolConverter.token()));

        bool successOfTransferFrom = _poolToken.transferFrom(msg.sender, address(this), _amount);
        require(successOfTransferFrom);

        IERC20Token reserveToken;
        uint256[] memory reserveAmountBefore;
        for (uint256 i = 0; i < _reserveTokens.length; i++) {
            reserveToken = _reserveTokens[i];
            reserveAmountBefore[i] = reserveToken.balanceOf(address(this));
        }

        _liquidityPoolConverter.removeLiquidity(_amount, _reserveTokens, _reserveMinReturnAmounts);

        uint256 reserveAmount;
        for (uint256 i = 0; i < _reserveTokens.length; i++) {
            reserveToken = _reserveTokens[i];
            
            reserveAmount = reserveToken.balanceOf(address(this)).sub(reserveAmountBefore[i]); 
            require(reserveAmount >= _reserveMinReturnAmounts[i], "ERR_ZERO_TARGET_AMOUNT");

            if (address(reserveToken) == wrbtcTokenAddress) {
                IWrbtcERC20(wrbtcTokenAddress).withdraw(reserveAmount);
                msg.sender.transfer(reserveAmount);
            } else {
                IERC20Token(reserveToken).transfer(msg.sender, reserveAmount);
            }

            emit LiquidityRemovedFromV1(msg.sender, address(reserveToken), reserveAmount);
        }
    }

}