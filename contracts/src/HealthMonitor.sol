// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Per-venue health signals. On the real protocol a per-protocol ADAPTER
///         implements this (utilization from the lending market, pause from the
///         guardian, peg from the oracle); the allocator depends only on this
///         interface, so wiring a real venue at the P7 canary is a config swap.
interface IHealthSignals {
    function utilizationBps() external view returns (uint256); // 0..10000 (withdraw risk)
    function depositsPaused() external view returns (bool);
    function pegBps() external view returns (uint256);         // 10000 = perfect peg
}

/// @title HealthMonitor
/// @notice Watches each parked venue and classifies it into a graduated risk tier
///         the AllocatorVault uses to drive its emergency-exit policy:
///           HEALTHY   → normal
///           CAUTION   → stop ADDING (utilization elevated)
///           STRESS    → flee primary → whitelisted BACKUP
///           EMERGENCY → pull ALL parked to base, await human review
///         Thresholds are OWNER-configured risk params (not an agent power). The
///         monitor only READS signals + emits a classification; it never moves funds.
contract HealthMonitor {
    enum Tier { HEALTHY, CAUTION, STRESS, EMERGENCY }

    address public owner;

    // utilization thresholds (bps of capacity used)
    uint256 public utilCautionBps;   // >= this → at least CAUTION
    uint256 public utilStressBps;    // >= this → at least STRESS (withdraw at risk)
    // peg thresholds (share price as bps of par; LOWER is worse)
    uint256 public pegStressBps;     // <= this → at least STRESS
    uint256 public pegEmergencyBps;  // <= this → EMERGENCY (severe depeg)

    event ConfigUpdated(uint256 utilCautionBps, uint256 utilStressBps, uint256 pegStressBps, uint256 pegEmergencyBps);
    event OwnerTransferred(address indexed from, address indexed to);

    error NotOwner();
    error BadConfig();

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(
        uint256 _utilCautionBps,
        uint256 _utilStressBps,
        uint256 _pegStressBps,
        uint256 _pegEmergencyBps
    ) {
        owner = msg.sender;
        _setConfig(_utilCautionBps, _utilStressBps, _pegStressBps, _pegEmergencyBps);
    }

    function setConfig(
        uint256 _utilCautionBps,
        uint256 _utilStressBps,
        uint256 _pegStressBps,
        uint256 _pegEmergencyBps
    ) external onlyOwner {
        _setConfig(_utilCautionBps, _utilStressBps, _pegStressBps, _pegEmergencyBps);
    }

    function _setConfig(uint256 c, uint256 s, uint256 pS, uint256 pE) internal {
        // caution must trip before stress; severe depeg must be below the stress peg
        if (!(c <= s && s <= 10_000 && pE <= pS && pS <= 10_000)) revert BadConfig();
        utilCautionBps = c;
        utilStressBps = s;
        pegStressBps = pS;
        pegEmergencyBps = pE;
        emit ConfigUpdated(c, s, pS, pE);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "monitor: zero owner");
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Classify a venue. Worst applicable signal wins.
    function tierOf(address venue) public view returns (Tier) {
        IHealthSignals v = IHealthSignals(venue);

        // pause / severe depeg → EMERGENCY (pull everything to base)
        if (v.depositsPaused()) return Tier.EMERGENCY;
        uint256 peg = v.pegBps();
        if (peg <= pegEmergencyBps) return Tier.EMERGENCY;

        // moderate depeg OR withdraw-at-risk utilization → STRESS (flee to backup)
        uint256 util = v.utilizationBps();
        if (peg <= pegStressBps || util >= utilStressBps) return Tier.STRESS;

        // elevated utilization → CAUTION (stop adding)
        if (util >= utilCautionBps) return Tier.CAUTION;

        return Tier.HEALTHY;
    }

    function isHealthy(address venue) external view returns (bool) {
        return tierOf(venue) == Tier.HEALTHY;
    }
}
