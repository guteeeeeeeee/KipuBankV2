// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title Kipu Bank V2
 * @notice banco que permite depositos y retiros de ETH/ERC20 con conversion a USD-6 por Chainlink.
 */

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,      // precio (token/USD) con 'decimals()' del feed
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

contract Kipu_Bank is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ROL administrador
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // variables
    uint8 public constant USD_DECIMALS = 6;
    uint256 public constant MIN_DEPOSIT = 0.000001 ether;
    uint256 public constant MIN_WITHDRAW = 0.000001 ether;
    // @notice cantidad de depositos totales
    uint256 public s_deposit_count = 0;
    // @notice cantidad de retiros totales
    uint256 public s_withdraw_count = 0;
    /// @notice limite global de depositos
    uint256 private constant s_threshold_deposits = 1000;
    ///@notice variable constante para almacenar el latido (heartbeat) del Data Feed
    uint16 constant ORACLE_HEARTBEAT = 3600;

    uint256 public immutable i_withdrawPerTxLimit; // limite por retiro de ETH
    ///@notice variable constante para almacenar el factor de decimales
    uint256 constant DECIMAL_FACTOR = 1 * 10 ** 20;

    //devuelve si el token esta habilitado
    mapping(address => bool)  public s_tokenEnabled; // ETH = address(0)
    ///@notice variable para almacenar la dirección del Chainlink Feed
    AggregatorV3Interface public immutable s_feeds; // ETH/USD
    mapping(address => AggregatorV3Interface) public s_tokenFeeds; // token ERC20 -> USD feed

    // token => user => amount (en unidades del token)
    mapping(address token => mapping(address user => uint256)) private s_balances;
    // suma total del banco valuada en USD6
    uint256 public s_totalUSD6;
    // cap global del banco en USD6
    uint256 public s_bankCapUsd6;

    //EVENTOS
    event TokenEnabled(address indexed token, bool enabled);
    event BankCapUpdated(uint256 newCapUsd6);
    event PriceFeedSet(address indexed token, address indexed feed, uint8 priceDecimals);
    event Deposit(address indexed user, address indexed token, uint256 amountToken, uint256 amountUsd6);
    event Withdraw(address indexed user, address indexed token, uint256 amountToken, uint256 amountUsd6);

    // ERRORES
    error ZeroAmount();
    error TokenNotEnabled(address token);
    error NoPriceFeed(address token);
    error NegativePrice(address token);
    error InsufficientBalance(address token, uint256 requested, uint256 available);
    error WithdrawLimitExceeded(uint256 requested, uint256 perTxLimit);
    error CapExceeded(uint256 capUsd6, uint256 newTotalUsd6);
    error KipuBank_OracleCompromised();
    error KipuBank_StalePrice();
    error FailTransference(address user, uint256 amount);
    error ExceededDepositsThreshold(uint256 threshold);

    modifier below_threshold_deposits(){
        if(s_deposit_count >= s_threshold_deposits){ //si se llego al limite de depositos
            revert ExceededDepositsThreshold(s_threshold_deposits);
        }
        _;
    }

    // @param i_withdrawPerTxLimit Limite por transaccion para retiros (wei)
    // @param bankCapUsd6 Cap global del banco en USD6
    // @param ethUsdFeed address del Aggregator ETH/USD de Chainlink en la red actual
    constructor(uint256 withdrawPerTxLimitNative, uint256 bankCapUsd6, address ethUsdFeed) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        // se habilita ETH por defecto y se usa address(0)
        s_tokenEnabled[address(0)] = true;
        emit TokenEnabled(address(0), true);

        s_feeds = AggregatorV3Interface(ethUsdFeed);
        uint8 priceDecimals = s_feeds.decimals();
        emit PriceFeedSet(address(0), ethUsdFeed, priceDecimals);

        i_withdrawPerTxLimit = withdrawPerTxLimitNative;
        s_bankCapUsd6 = bankCapUsd6;
        emit BankCapUpdated(bankCapUsd6);
    }

    /// @notice habilitar o deshabilitar un token ERC20
    function setTokenEnabled(address token, bool enabled) external onlyRole(ADMIN_ROLE) {
        s_tokenEnabled[token] = enabled;
        emit TokenEnabled(token, enabled);
    }

    /// @notice actualizar el feed USD de un token ERC20
    function setPriceFeed(address token, address feed) external onlyRole(ADMIN_ROLE) {
        require(token != address(0), "ETH feed fijo en s_feeds");
        AggregatorV3Interface aggr = AggregatorV3Interface(feed);
        s_tokenFeeds[token] = aggr;
        emit PriceFeedSet(token, feed, aggr.decimals()); //se actualizo el feed
    }

    /// @notice actualizar el bank cap
    function setBankCapUsd6(uint256 newCapUsd6) external onlyRole(ADMIN_ROLE) {
        s_bankCapUsd6 = newCapUsd6;
        emit BankCapUpdated(newCapUsd6);
    }

    /// @notice depositar ETH y pasarlo a USD6 con Chainlink
    function depositETH() public payable below_threshold_deposits nonReentrant {
        if (!s_tokenEnabled[address(0)]) revert TokenNotEnabled(address(0));
        if (msg.value == 0) revert ZeroAmount();
        if (msg.value < MIN_DEPOSIT) revert ZeroAmount();

        uint256 usd6 = convertEthInUSD(msg.value); //lo que pasaron
        uint256 newTotal = s_totalUSD6 + usd6; //se agrega al total
        if (newTotal > s_bankCapUsd6) revert CapExceeded(s_bankCapUsd6, newTotal); //si supera el cap

        s_balances[address(0)][msg.sender] += msg.value; //actualizo saldo
        s_totalUSD6 = newTotal; //actualizo monto total
        s_deposit_count += 1;

        emit Deposit(msg.sender, address(0), msg.value, usd6);
    }

    /// @notice depositar un ERC20 habilitado, pasarlo a USD6
    function depositToken(address token, uint256 amount) external below_threshold_deposits nonReentrant {
        if (token == address(0)) revert TokenNotEnabled(token); //que no sea ETH
        if (!s_tokenEnabled[token]) revert TokenNotEnabled(token);
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount); //me lo transfiero

        uint256 usd6 = _convertTokenInUSD(token, amount); //lo paso a usd6
        uint256 newTotal = s_totalUSD6 + usd6;
        if (newTotal > s_bankCapUsd6) revert CapExceeded(s_bankCapUsd6, newTotal); //si supera el cap

        s_balances[token][msg.sender] += amount; //actualizo saldo del usuario
        s_totalUSD6 = newTotal; //actualizo monto total del banco
        s_deposit_count += 1;

        emit Deposit(msg.sender, token, amount, usd6);
    }

    /// @notice retirar ETH
    function withdrawETH(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount < MIN_WITHDRAW) revert ZeroAmount();
        if (amount > i_withdrawPerTxLimit) revert WithdrawLimitExceeded(amount, i_withdrawPerTxLimit); //que no supere el limite por transaccion

        uint256 bal = s_balances[address(0)][msg.sender]; //balance del usuario
        if (bal < amount) revert InsufficientBalance(address(0), amount, bal); //si pide retirar mas de lo que tiene

        uint256 usd6 = convertEthInUSD(amount); //lo paso a usd6

        s_balances[address(0)][msg.sender] = bal - amount; //actualizo saldo
        s_totalUSD6 = s_totalUSD6 - usd6; //actualizo total del banco
        s_withdraw_count += 1;

        _transferirEth(amount);

        emit Withdraw(msg.sender, address(0), amount, usd6);
    }

    /// @notice retirar monto de un token ERC20
    function withdrawToken(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert TokenNotEnabled(token); //que no sea ETH
        if (!s_tokenEnabled[token]) revert TokenNotEnabled(token);
        if (amount == 0) revert ZeroAmount();

        uint256 bal = s_balances[token][msg.sender]; //balance del usuario
        if (bal < amount) revert InsufficientBalance(token, amount, bal);

        uint256 usd6 = _convertTokenInUSD(token, amount); //lo paso a usd6

        s_balances[token][msg.sender] = bal - amount; //actualiza saldo
        s_totalUSD6 = s_totalUSD6 - usd6; //disminuye total del banco
        s_withdraw_count += 1;

        IERC20(token).safeTransfer(msg.sender, amount); //le transfiero al usuario

        emit Withdraw(msg.sender, token, amount, usd6);
    }

    // @notice balance del usuario de ese token
    function balanceOf(address token, address user) external view returns (uint256) {
        return s_balances[token][user];
    }

    /// @notice cotiza un monto a USD6
    function quoteUsd6(address token, uint256 amount) external view returns (uint256) {
        if (token == address(0)) return convertEthInUSD(amount);
        return _convertTokenInUSD(token, amount);
    }

    /// @dev ETH directo cuenta como deposito
    receive() external payable {
        depositETH();
    }

    /// @dev si llega data con ETH cuenta como deposito
    // sin ETH => revert !!
    fallback() external payable {
        if (msg.value == 0) revert("Funcion inexistente");
        depositETH();
    }

    /// @notice para consultar el precio en USD del ETH
    function chainlinkFeed() internal view returns (uint256 ethUSDPrice_) {
        (, int256 ethUSDPrice,, uint256 updatedAt,) = s_feeds.latestRoundData(); //consulta el precio

        if (ethUSDPrice <= 0) revert KipuBank_OracleCompromised();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert KipuBank_StalePrice();

        ethUSDPrice_ = uint256(ethUSDPrice);
    }

    /// @notice convierte monto en ETH (wei) a USD6 usando el feed ETH/USD
    function convertEthInUSD(uint256 _ethAmount) internal view returns (uint256 convertedAmount_) {
        // USD6 = (wei * price) / DECIMAL_FACTOR
        convertedAmount_ = (_ethAmount * chainlinkFeed()) / DECIMAL_FACTOR;
    }

    /// @dev devuelve decimales del token; para ETH asume 18; para ERC20 intenta leer `decimals()`.
    function _tokenDecimals(address token) internal view returns (uint8) {
        if (token == address(0)) return 18; // ETH

        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (ok && data.length >= 32) {
            uint8 dec = uint8(uint256(bytes32(data)));
            return dec == 0 ? 18 : dec;
        }
        return 18;
    }

    /// @dev convierte ERC20 a USD6 con su feed TOKEN/USD
    function _convertTokenInUSD(address token, uint256 tokenAmount) internal view returns (uint256 usd6_) {
        AggregatorV3Interface feed = s_tokenFeeds[token];
        if (address(feed) == address(0)) revert NoPriceFeed(token);

        (, int256 px,, uint256 updatedAt,) = feed.latestRoundData(); //consulta
        if (px <= 0) revert NegativePrice(token);
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert KipuBank_StalePrice();

        uint8 priceDecimals = feed.decimals();
        uint8 tokenDecimals = _tokenDecimals(token);

        // USD6 = (amount * price) / 10^(tokenDecimals + priceDecimals - USD_DECIMALS)
        uint256 factorExp = uint256(tokenDecimals) + uint256(priceDecimals) - uint256(USD_DECIMALS);
        uint256 factor = 10 ** factorExp;

        usd6_ = Math.mulDiv(tokenAmount, uint256(px), factor); //monto en usd6
    }

    // @notice funcion privada para realizar la transferencia de ether
    // @param monto El monto a ser transferido
    // @dev necesita revertir si falla
    function _transferirEth(uint256 amount) private {
        (bool sucess, ) = msg.sender.call{value: amount}("");
        if (!sucess) revert FailTransference(msg.sender,amount);
    }
}
