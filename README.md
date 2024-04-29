# Asset Management Trusts Contract Documentation

[Business Idea Document](https://docs.google.com/document/d/1uY80XoDcEFi39YQkF3eXGCdtpBTSBMrA1IqjUCgE1m8/edit?usp=sharing)

[Contract Review Document](https://docs.google.com/document/d/1dMzREk22NHCXxLXIE8LhBCPNNVVeEPutTdZXubmmgEI/edit?usp=sharing)

## Overview

The AMT (Asset Management Token) contract is designed to facilitate the management and transfer of various assets, including ERC20 tokens, ERC721 tokens, and ERC1155 tokens, in various of cases:

- Assets Inheritance.
- Collect money in trust and faithfully distribute the interest after a specified time.
- Bonds, but without trust returns.
- Retain access to assets in the event of loss.

The contract provides functionalities for assigning successors, initiating voting processes, confirming lost access, and transferring assets to successors.

## Features

- Supports ERC20, ERC721, and ERC1155 token standards.
- Allows property owners to set successors and guardians.
- Enables confirmation of lost access and subsequent asset transfer.
- Implements voting mechanisms to verify guardian consensus.
- Provides configurable parameters for voting quorum, confirmation lock, and more.

## Contract Details

- **Fee Structure**:
  - Fee address
  - 1% fee (customizable) on asset transfers
- **Lock Periods** (customizable):
  - Confirmation Lock: 180 days
  - Minimum Property Lock: 360 days
  - Contingency Period: 3600 days
- **Limitations**:
  - Maximum Guardians: 10
  - Maximum Successors: 10

## Functions

1. `setFeeAddress(address _feeAddress)`: Sets the fee recipient address.
2. `setSuccessors(Successors calldata _newSuccessors)`: Sets successors for the property owner.
3. `setGuardians(uint256 _quorum, address[] calldata _guardians)`: Sets guardians and voting quorum.
4. `deleteProperty()`: Deletes the property if conditions are met.
5. `createProperty(uint256 _quorum, address[] calldata _guardians, Successors calldata _successors)`: Creates a new property with specified guardians and successors.
6. `imActive()`: Confirms that the property owner is still active.
7. `confirmLostAccess(address propertyOwner)`: Confirms lost access with guardian votes.
8. `withdrawProperty(address propertyOwner, PropertyTokens calldata tokens)`: Allows successors to withdraw assets after lost access confirmation.
9. `getPropertyState(address propertyOwner)`: Retrieves the current state of the property.

## Events

- `SuccessorsChanged(address propertyOwner, Successors newSuccessors)`: Emitted when successors are changed for a property.
- `PropertyDeleted(address propertyOwner)`: Emitted when a property is deleted.
- `GuardiansChanged(address user, uint256 newVoteQuorum, address[] newGuardians)`: Emitted when guardians and quorum are changed.
- `CreateProperty(address user, Property newProperty)`: Emitted when a new property is created.
- `OwnerActive(address propertyOwner, uint256 newExpirationTime)`: Emitted when the property owner confirms activity.
- `LostAccessConfirmed(address propertyOwner, uint256 lostAccessConfirmationTime)`: Emitted when lost access is confirmed.
- `GetProperty(address propertyOwner, address successor)`: Emitted when assets are transferred to a successor.

## Usage

1. Deploy the contract with desired configuration parameters.
2. Set fee recipient address using `setFeeAddress`.
3. Create properties with specified guardians and successors using `createProperty`.
4. Allow contract to spend your ERC20, ERC720, ERC1155 (that would be needed to withdrawProperty).
5. Set successors and guardians for existing properties using `setSuccessors` and `setGuardians`.
6. Confirm active status periodically using `imActive`.
7. Confirm lost access or when property should be distributed, transfer assets using `confirmLostAccess` and `withdrawProperty`.

## Security and Tests

- Allow contract to spend your ERC20, ERC720, ERC1155 is safe cause only owner can set successors for their property
- Our first implementation with the merkle trees to save heirs in testament contract was well tested, but since we simplified it, we didn't have time to rewrite the tests. Since the logic remained similar, the contract should meet the security requirements.

![alt text](image.png)
