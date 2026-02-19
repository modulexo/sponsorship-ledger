# SponsorshipLedger

**Deterministic accounting primitive for registering recyclable ERC-20 inventory and issuing consumable unit allowances.**

---

## Definition

`SponsorshipLedger` accepts ERC-20 tokens from a sponsor, permanently removes them from circulation, and credits a beneficiary with recyclable accounting units.

The ledger does not distribute value.  
It records irreversible inventory provision for later execution by `RecyclingEngine`.

All state transitions are enforced on-chain.

---

## What This Contract Does

- Accepts ERC-20 token sponsorship  
- Transfers tokens to an irreversible sink address  
- Credits beneficiary with recyclable accounting units  
- Prevents sponsor self-benefit  
- Tracks beneficiary recyclable balances  
- Emits verifiable sponsorship events  

### Core Behavior

1. Sponsor transfers ERC-20 tokens.
2. Tokens are permanently removed from circulation.
3. Beneficiary receives accounting units.
4. Units become consumable by `RecyclingEngine`.

---

## What This Contract Does NOT Do

- Does **not** distribute native rewards  
- Does **not** mint accounting weight  
- Does **not** route fees  
- Does **not** determine asset listing  
- Does **not** guarantee value recovery  
- Does **not** provide compensation  

This is an inventory registration layer only.

---

## Scope Limitation

`SponsorshipLedger` does not execute recycling.

It relies on:

- **RecycleAssetRegistry** — defines eligible assets and unit rates  
- **RecyclingEngine** — consumes units and handles execution  
- **Fee Router** — routes native fees  

The ledger is accounting-only.

---

## Deployment Status

- **Ownership:** Set per deployment  
- **Upgradeability:** Non-upgradeable  
- **Immutability:** Final after `renounceOwnership()`  

Refer to GitBook for deployed addresses and verification.

---

## Documentation

Full documentation:

https://docs.modulexo.com
