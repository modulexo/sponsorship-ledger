// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Ownable2StepLite.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IRecycleAssetRegistryLedger {
    function assets(address token)
        external
        view
        returns (bool listed, bool enabled, uint8 decimals, uint256 unitsPer1e18Native, uint256 capUnits);
}

/**
 * SponsorshipLedgerV2 (HARDENED)
 * - fee-on-transfer safe crediting (credit what BlackHole actually receives)
 * - sponsor immutability while any balances exist (activeTokenCount > 0)
 * - beneficiary can clear sponsor only when empty, or by forfeiting ALL remaining balances
 */
contract SponsorshipLedger is Ownable2StepLite {
    using SafeERC20 for IERC20;

    error LEDGER_ZERO_ADDRESS();
    error LEDGER_SELF_SPONSOR_FORBIDDEN();
    error LEDGER_ASSET_NOT_ENABLED();
    error LEDGER_SPONSOR_LOCKED();
    error LEDGER_ONLY_ENGINE();
    error LEDGER_INSUFFICIENT_ALLOWANCE();
    error LEDGER_CAP_EXCEEDED();
    error LEDGER_NOTHING_TO_FORFEIT();
    error LEDGER_NOT_EMPTY();
    error LEDGER_NO_TOKENS_RECEIVED();

    event EngineSet(address indexed engine);

    event Sponsored(
        address indexed sponsor,
        address indexed beneficiary,
        address indexed token,
        uint256 tokenAmountUnits, // requested
        uint256 newAllowanceUnits
    );

    event SponsoredReceived(
        address indexed sponsor,
        address indexed beneficiary,
        address indexed token,
        uint256 requestedUnits,
        uint256 receivedUnits
    );

    event AllowanceConsumed(
        address indexed beneficiary,
        address indexed token,
        uint256 unitsConsumed,
        uint256 remainingUnits
    );

    event AllowanceForfeited(
        address indexed beneficiary,
        address indexed token,
        uint256 unitsForfeited
    );

    event SponsorCleared(address indexed beneficiary, address indexed oldSponsor);

    /// @notice Summary event so indexers don’t reconstruct from per-token events.
    event SponsorClearedWithForfeitSummary(
        address indexed beneficiary,
        address indexed oldSponsor,
        uint256 tokensCleared,
        uint256 totalUnitsForfeited,
        bool sponsorCleared
    );

    IRecycleAssetRegistryLedger public immutable registry;
    address public immutable blackHole;

    address public engine;

    mapping(address => address) public sponsorOf;
    mapping(address => mapping(address => uint256)) public recyclableBalance;

    // Lifetime analytics (do NOT decrement on forfeiture)
    mapping(address => uint256) public totalSponsoredUnitsByToken;
    mapping(address => uint256) public totalAllocatedUnitsByBeneficiary;

    // Number of tokens with nonzero recyclableBalance for beneficiary
    mapping(address => uint32) public activeTokenCount;

    constructor(address registry_, address blackHole_, address initialOwner) Ownable2StepLite(initialOwner) {
        if (registry_ == address(0) || blackHole_ == address(0)) revert LEDGER_ZERO_ADDRESS();
        registry = IRecycleAssetRegistryLedger(registry_);
        blackHole = blackHole_;
    }

    function setEngine(address engine_) external onlyOwner {
        if (engine_ == address(0)) revert LEDGER_ZERO_ADDRESS();
        engine = engine_;
        emit EngineSet(engine_);
    }

    function sponsor(address beneficiary, address token, uint256 tokenAmountUnits) external {
        if (beneficiary == address(0) || token == address(0)) revert LEDGER_ZERO_ADDRESS();
        if (beneficiary == msg.sender) revert LEDGER_SELF_SPONSOR_FORBIDDEN();
        if (tokenAmountUnits == 0) revert LEDGER_INSUFFICIENT_ALLOWANCE();

        (bool listed, bool enabled, , , uint256 capUnits) = registry.assets(token);
        if (!listed || !enabled) revert LEDGER_ASSET_NOT_ENABLED();

        address prev = sponsorOf[beneficiary];
        if (prev == address(0)) {
            sponsorOf[beneficiary] = msg.sender;
        } else if (prev != msg.sender) {
            // sponsor switching ONLY if beneficiary is empty across all tokens
            if (activeTokenCount[beneficiary] != 0) revert LEDGER_SPONSOR_LOCKED();
            sponsorOf[beneficiary] = msg.sender;
        }

        // Measure received (fee-on-transfer safe)
        uint256 bhBefore = IERC20(token).balanceOf(blackHole);

        IERC20(token).safeTransferFrom(msg.sender, blackHole, tokenAmountUnits);

        uint256 bhAfter = IERC20(token).balanceOf(blackHole);
        uint256 received = bhAfter - bhBefore;
        if (received == 0) revert LEDGER_NO_TOKENS_RECEIVED();

        // Enforce cap on actual received units
        if (capUnits != 0) {
            uint256 newTotal = totalSponsoredUnitsByToken[token] + received;
            if (newTotal > capUnits) revert LEDGER_CAP_EXCEEDED();
            totalSponsoredUnitsByToken[token] = newTotal;
        } else {
            totalSponsoredUnitsByToken[token] += received;
        }

        uint256 beforeBal = recyclableBalance[beneficiary][token];
        uint256 newAllowance = beforeBal + received;
        recyclableBalance[beneficiary][token] = newAllowance;

        if (beforeBal == 0) {
            unchecked {
                activeTokenCount[beneficiary] += 1;
            }
        }

        totalAllocatedUnitsByBeneficiary[beneficiary] += received;

        emit Sponsored(msg.sender, beneficiary, token, tokenAmountUnits, newAllowance);
        emit SponsoredReceived(msg.sender, beneficiary, token, tokenAmountUnits, received);
    }

    function consume(address beneficiary, address token, uint256 units) external {
        if (msg.sender != engine) revert LEDGER_ONLY_ENGINE();

        uint256 bal = recyclableBalance[beneficiary][token];
        if (units == 0 || bal < units) revert LEDGER_INSUFFICIENT_ALLOWANCE();

        uint256 afterBal;
        unchecked {
            afterBal = bal - units;
            recyclableBalance[beneficiary][token] = afterBal;
        }

        if (afterBal == 0) {
            unchecked {
                activeTokenCount[beneficiary] -= 1;
            }
        }

        emit AllowanceConsumed(beneficiary, token, units, afterBal);
    }

    function clearSponsorIfEmpty() external {
        address beneficiary = msg.sender;
        address oldSponsor = sponsorOf[beneficiary];
        if (oldSponsor == address(0)) revert LEDGER_NOTHING_TO_FORFEIT();
        if (activeTokenCount[beneficiary] != 0) revert LEDGER_NOT_EMPTY();

        sponsorOf[beneficiary] = address(0);
        emit SponsorCleared(beneficiary, oldSponsor);
    }

    /**
     * @notice Forfeit remaining allowance for provided tokens; sponsor clears ONLY if beneficiary becomes empty.
     * @dev Passing an incomplete token list can forfeit some balances without clearing sponsor.
     *      Your UI should pass all tokens with nonzero balances.
     */
    function clearSponsorAndForfeit(address[] calldata tokens) external {
        address beneficiary = msg.sender;
        address oldSponsor = sponsorOf[beneficiary];

        uint256 totalForfeited;
        uint256 tokensCleared;

        for (uint256 i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            uint256 bal = recyclableBalance[beneficiary][t];
            if (bal == 0) continue;

            recyclableBalance[beneficiary][t] = 0;
            totalForfeited += bal;
            tokensCleared += 1;

            unchecked {
                activeTokenCount[beneficiary] -= 1;
            }

            emit AllowanceForfeited(beneficiary, t, bal);
        }

        if (totalForfeited == 0) revert LEDGER_NOTHING_TO_FORFEIT();

        bool sponsorCleared;
        if (oldSponsor != address(0) && activeTokenCount[beneficiary] == 0) {
            sponsorOf[beneficiary] = address(0);
            sponsorCleared = true;
            emit SponsorCleared(beneficiary, oldSponsor);
        }

        emit SponsorClearedWithForfeitSummary(
            beneficiary,
            oldSponsor,
            tokensCleared,
            totalForfeited,
            sponsorCleared
        );
    }
}
