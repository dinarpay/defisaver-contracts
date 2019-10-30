pragma solidity ^0.5.0;

import "../../interfaces/ExchangeInterface.sol";
import "../../SaverLogger.sol";
import "../../Discount.sol";

import "../maker/Spotter.sol";
import "../maker/Jug.sol";
import "../maker/DaiJoin.sol";

import "./MCDExchange.sol";
import "./MCDTokenExchange.sol";
import "./ExchangeHelper.sol";
import "./SaverProxyHelper.sol";

/// @title Implements Boost and Repay for MCD CDPs
contract MCDSaverProxy is SaverProxyHelper, ExchangeHelper {

    // KOVAN
    address public constant VAT_ADDRESS = 0x6e6073260e1a77dFaf57D0B92c44265122Da8028;
    address public constant MANAGER_ADDRESS = 0x1Cb0d969643aF4E929b3FafA5BA82950e31316b8;
    address public constant JUG_ADDRESS = 0x3793181eBbc1a72cc08ba90087D21c7862783FA5;
    address public constant DAI_JOIN_ADDRESS = 0x61Af28390D0B3E806bBaF09104317cb5d26E215D;

    address payable public constant OASIS_TRADE = 0x8EFd472Ca15BED09D8E9D7594b94D4E42Fe62224;

    address public constant DAI_ADDRESS = 0x1f9BEAf12D8db1e50eA8a5eD53FB970462386aA0;
    address public constant SAI_ADDRESS = 0xC4375B7De8af5a38a93548eb8453a498222C4fF2;

    address public constant LOGGER_ADDRESS = 0x32d0e18f988F952Eb3524aCE762042381a2c39E5;

    address public constant ETH_JOIN_ADDRESS = 0xc3AbbA566bb62c09b7f94704d8dFd9800935D3F9;

    address public constant MCD_EXCHANGE_ADDRESS = 0x2f0449f3E73B1E343ADE21d813eE03aA23bfd2e8;

    address public constant SPOTTER_ADDRESS = 0xF5cDfcE5A0b85fF06654EF35f4448E74C523c5Ac;

    address public constant DISCOUNT_ADDRESS = 0x1297c1105FEDf45E0CF6C102934f32C4EB780929;
    address payable public constant WALLET_ID = 0x54b44C6B18fc0b4A1010B21d524c338D1f8065F6;
    bytes32 public constant ETH_ILK = 0x4554482d41000000000000000000000000000000000000000000000000000000;

    uint public constant SERVICE_FEE = 400; // 0.25% Fee

    address payable public constant MCD_TOKEN_EXCHANGE = 0x1f116BC86C83D1562df05b037b0FecA4A59680AB;

    Manager public constant manager = Manager(MANAGER_ADDRESS);
    Vat public constant vat = Vat(VAT_ADDRESS);
    DaiJoin public constant daiJoin = DaiJoin(DAI_JOIN_ADDRESS);
    Spotter public constant spotter = Spotter(SPOTTER_ADDRESS);
    MCDTokenExchange public constant tokenExchange = MCDTokenExchange(MCD_TOKEN_EXCHANGE);

    /// @notice Checks if the collateral amount is increased after boost
    /// @param _cdpId The Id of the CDP
    modifier boostCheck(uint _cdpId) {
        bytes32 ilk = manager.ilks(_cdpId);
        address urn = manager.urns(_cdpId);

        (uint collateralBefore, ) = vat.urns(ilk, urn);

        _;

        (uint collateralAfter, ) = vat.urns(ilk, urn);

        require(collateralAfter > collateralBefore);
    }

    /// @notice Checks if ratio is increased after repay
    /// @param _cdpId The Id of the CDP
    modifier repayCheck(uint _cdpId) {
        bytes32 ilk = manager.ilks(_cdpId);

        uint beforeRatio = getRatio(_cdpId, ilk);

        _;

        uint afterRatio = getRatio(_cdpId, ilk);

        require(afterRatio > beforeRatio || afterRatio == 0);
    }

    /// @notice Repay - draws collateral, converts to Dai and repays the debt
    /// @dev Must be called by the DSProxy contract that owns the CDP
    /// @param _cdpId Id of the CDP
    /// @param _joinAddr Address of the join contract for the CDP collateral
    /// @param _amount Amount of collateral to withdraw
    /// @param _minPrice Minimum acceptable price for collateral -> Dai conversion
    /// @param _exchangeType The type of exchange to be used for conversion
    /// @param _gasCost Used for Monitor, estimated gas cost of tx
    function repay(
        uint _cdpId,
        address _joinAddr,
        uint _amount,
        uint _minPrice,
        uint _exchangeType,
        uint _gasCost
    ) external repayCheck(_cdpId) {

        address owner = getOwner(manager, _cdpId);
        bytes32 ilk = manager.ilks(_cdpId);
        address collateralAddr = getCollateralAddr(_joinAddr);

        drawCollateral(_cdpId, ilk, _joinAddr, _amount);

        tokenExchange.newToOld(collateralAddr, _amount);

        // TESTING: SWITCH TO DAI_ADDRESS
        uint daiAmount = swap(tokenExchange.getOld(collateralAddr), SAI_ADDRESS, _amount, _minPrice, _exchangeType);

        MCDExchange(MCD_EXCHANGE_ADDRESS).saiToDai(daiAmount); // TESTING

        uint daiAfterFee = sub(daiAmount, getFee(daiAmount, _gasCost, owner));

        paybackDebt(_cdpId, ilk, daiAfterFee, owner);

        SaverLogger(LOGGER_ADDRESS).LogRepay(_cdpId, owner, _amount, daiAmount);
    }

    /// @notice Boost - draws Dai, converts to collateral and adds to CDP
    /// @dev Must be called by the DSProxy contract that owns the CDP
    /// @param _cdpId Id of the CDP
    /// @param _joinAddr Address of the join contract for the CDP collateral
    /// @param _daiAmount Amount of Dai to withdraw
    /// @param _minPrice Minimum acceptable price for collateral -> Dai conversion
    /// @param _exchangeType The type of exchange to be used for conversion
    /// @param _gasCost Used for Monitor, estimated gas cost of tx
    function boost(
        uint _cdpId,
        address _joinAddr,
        uint _daiAmount,
        uint _minPrice,
        uint _exchangeType,
        uint _gasCost
    ) external { //TESTING: return boost check

        address owner = getOwner(manager, _cdpId);

        drawDai(_cdpId, manager.ilks(_cdpId), _daiAmount);

        uint daiAfterFee = sub(_daiAmount, getFee(_daiAmount, _gasCost, owner));

        // TODO: remove only used for testing
        MCDExchange(MCD_EXCHANGE_ADDRESS).daiToSai(daiAfterFee);
        ERC20(DAI_ADDRESS).transfer(MCD_EXCHANGE_ADDRESS, ERC20(DAI_ADDRESS).balanceOf(address(this)));

        //TESTING: change to DAI address and tokenExchange
        ERC20(SAI_ADDRESS).approve(OASIS_TRADE, daiAfterFee);
        uint collateralAmount = swap(SAI_ADDRESS, tokenExchange.getOld(getCollateralAddr(_joinAddr)), daiAfterFee, _minPrice, _exchangeType);

        tokenExchange.oldToNew(getCollateralAddr(_joinAddr), 10000000);

        addCollateral(_cdpId, _joinAddr, 10000000);

        SaverLogger(LOGGER_ADDRESS).LogBoost(_cdpId, owner, _daiAmount, collateralAmount);
    }

    /// @notice Draws Dai from the CDP
    /// @dev If _daiAmount is bigger than max available we'll draw max
    /// @param _cdpId Id of the CDP
    /// @param _ilk Ilk of the CDP
    /// @param _daiAmount Amount of Dai to draw
    function drawDai(uint _cdpId, bytes32 _ilk, uint _daiAmount) internal {
        Jug(JUG_ADDRESS).drip(_ilk);

        uint maxAmount = getMaxDebt(_cdpId, _ilk);

        if (_daiAmount > maxAmount) {
            _daiAmount = sub(maxAmount, 1);
        }

        manager.frob(_cdpId, int(0), int(_daiAmount));
        manager.move(_cdpId, address(this), toRad(_daiAmount));

        if (vat.can(address(this), address(DAI_JOIN_ADDRESS)) == 0) {
            vat.hope(DAI_JOIN_ADDRESS);
        }

        DaiJoin(DAI_JOIN_ADDRESS).exit(address(this), _daiAmount);
    }

    /// @notice Adds collateral to the CDP
    /// @param _cdpId Id of the CDP
    /// @param _joinAddr Address of the join contract for the CDP collateral
    /// @param _amount Amount of collateral to add
    function addCollateral(uint _cdpId, address _joinAddr, uint _amount) internal {
        int convertAmount = toPositiveInt(convertTo18(_joinAddr, _amount));

        if (_joinAddr == ETH_JOIN_ADDRESS) {
            Join(_joinAddr).gem().deposit.value(_amount)();
            convertAmount = toPositiveInt(_amount);
        }

        Join(_joinAddr).gem().approve(_joinAddr, _amount);
        Join(_joinAddr).join(address(this), _amount);

        vat.frob(
            manager.ilks(_cdpId),
            manager.urns(_cdpId),
            address(this),
            address(this),
            convertAmount,
            0
        );

    }

    /// @notice Draws collateral and returns it to DSProxy
    /// @dev If _amount is bigger than max available we'll draw max
    /// @param _cdpId Id of the CDP
    /// @param _ilk Ilk of the CDP
    /// @param _joinAddr Address of the join contract for the CDP collateral
    /// @param _amount Amount of collateral to draw
    function drawCollateral(uint _cdpId, bytes32 _ilk, address _joinAddr, uint _amount) internal {
        uint maxCollateral = getMaxCollateral(_cdpId, _ilk);

        if (_amount > maxCollateral) {
            _amount = sub(maxCollateral, 1);
        }

        manager.frob(_cdpId, address(this), -toPositiveInt(_amount), 0);
        Join(_joinAddr).exit(address(this), _amount);

        if (_joinAddr == ETH_JOIN_ADDRESS) {
            Join(_joinAddr).gem().withdraw(_amount); // Weth -> Eth
        }
    }

    /// @notice Paybacks Dai debt
    /// @dev If the _daiAmount is bigger than the whole debt, returns extra Dai
    /// @param _cdpId Id of the CDP
    /// @param _ilk Ilk of the CDP
    /// @param _daiAmount Amount of Dai to payback
    /// @param _owner Address that owns the DSProxy that owns the CDP
    function paybackDebt(uint _cdpId, bytes32 _ilk, uint _daiAmount, address _owner) internal {
        address urn = manager.urns(_cdpId);

        uint wholeDebt = getAllDebt(VAT_ADDRESS, urn, urn, _ilk);

        if (_daiAmount > wholeDebt) {
            ERC20(DAI_ADDRESS).transfer(_owner, sub(_daiAmount, wholeDebt));
            _daiAmount = wholeDebt;
        }

        daiJoin.dai().approve(DAI_JOIN_ADDRESS, _daiAmount);
        daiJoin.join(urn, _daiAmount);

        manager.frob(_cdpId, 0, getPaybackAmount(VAT_ADDRESS, urn, _ilk));
    }

    /// @notice Calculates the fee amount
    /// @param _amount Dai amount that is converted
    /// @param _gasCost Used for Monitor, estimated gas cost of tx
    /// @param _owner The address that controlls the DSProxy that owns the CDP
    function getFee(uint _amount, uint _gasCost, address _owner) internal returns (uint feeAmount) {
        uint fee = SERVICE_FEE;

        if (Discount(DISCOUNT_ADDRESS).isCustomFeeSet(_owner)) {
            fee = Discount(DISCOUNT_ADDRESS).getCustomServiceFee(_owner);
        }

        feeAmount = (fee == 0) ? 0 : (_amount / fee);

        if (_gasCost != 0) {
            uint ethDaiPrice = getPrice(ETH_ILK);
            _gasCost = wmul(_gasCost, ethDaiPrice);

            feeAmount = add(feeAmount, _gasCost);
        }

        // fee can't go over 20% of the whole amount
        if (feeAmount > (_amount / 5)) {
            feeAmount = _amount / 5;
        }

        ERC20(DAI_ADDRESS).transfer(WALLET_ID, feeAmount);
    }

    /// @notice Gets the maximum amount of collateral available to draw
    /// @param _cdpId Id of the CDP
    /// @param _ilk Ilk of the CDP
    function getMaxCollateral(uint _cdpId, bytes32 _ilk) public view returns (uint) {
        uint price = getPrice(_ilk);

        (uint collateral, uint debt) = getCdpInfo(manager, _cdpId, _ilk);

        (, uint mat) = Spotter(SPOTTER_ADDRESS).ilks(_ilk);

        return sub(collateral, (wdiv(wmul(mat, debt), price)));
    }

    /// @notice Gets the maximum amount of debt available to generate
    /// @param _cdpId Id of the CDP
    /// @param _ilk Ilk of the CDP
    function getMaxDebt(uint _cdpId, bytes32 _ilk) public view returns (uint) {
        uint price = getPrice(_ilk);

        (, uint mat) = spotter.ilks(_ilk);
        (uint collateral, uint debt) = getCdpInfo(manager, _cdpId, _ilk);

        return sub(wdiv(wmul(collateral, price), mat), debt);
    }

    /// @notice Gets a price of the asset
    /// @param _ilk Ilk of the CDP
    function getPrice(bytes32 _ilk) public view returns (uint) {
        (, uint mat) = spotter.ilks(_ilk);
        (,,uint spot,,) = vat.ilks(_ilk);

        return rmul(rmul(spot, spotter.par()), mat);
    }

    /// @notice Gets CDP ratio
    /// @param _cdpId Id of the CDP
    /// @param _ilk Ilk of the CDP
    function getRatio(uint _cdpId, bytes32 _ilk) public view returns (uint) {
        uint price = getPrice( _ilk);

        (uint collateral, uint debt) = getCdpInfo(manager, _cdpId, _ilk);

        if (debt == 0) return 0;

        return rdiv(wmul(collateral, price), debt);
    }

}
