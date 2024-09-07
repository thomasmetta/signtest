// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ISP } from "@ethsign/sign-protocol-evm/src/interfaces/ISP.sol";
import { Attestation } from "@ethsign/sign-protocol-evm/src/models/Attestation.sol";
import { DataLocation } from "@ethsign/sign-protocol-evm/src/models/DataLocation.sol";

contract SimpleEscrow is Ownable {
    ISP public spInstance;
    uint64 public schemaId;
    address public customer;
    address public shipper;
    uint256 public amount;
    bool public shipmentConfirmed;
    bool public receiptConfirmed;

    error NotAuthorized();
    error InvalidState();
    error AttestationFailed();

    event EscrowInitialized(address indexed customer, address indexed shipper, uint256 amount);
    event ShipmentConfirmed(address indexed shipper, uint64 attestationId);
    event ReceiptConfirmed(address indexed customer, uint64 attestationId);
    event FundsReleased(address indexed shipper, uint256 amount);

    constructor(address instance, uint64 schemaId_) Ownable(_msgSender()) {
        spInstance = ISP(instance);
        schemaId = schemaId_;
    }

    function initializeEscrow(address _shipper) external payable {
        require(msg.value > 0, "Escrow amount must be greater than 0");
        require(shipper == address(0) && customer == address(0), "Escrow already initialized");

        customer = _msgSender();
        shipper = _shipper;
        amount = msg.value;

        emit EscrowInitialized(customer, shipper, amount);
    }

    function confirmShipment(bytes memory data) external {
        if (_msgSender() != shipper) revert NotAuthorized();
        if (shipmentConfirmed) revert InvalidState();

        bytes[] memory recipients = new bytes[](2);
        recipients[0] = abi.encode(shipper);
        recipients[1] = abi.encode(customer);

        Attestation memory attestation = Attestation({
            schemaId: schemaId,
            linkedAttestationId: 0,
            attestTimestamp: uint64(block.timestamp), // Corrected casting
            revokeTimestamp: 0,
            attester: address(this),
            validUntil: 0,
            dataLocation: DataLocation.ONCHAIN,
            revoked: false,
            recipients: recipients,
            data: data
        });

        uint64 attestationId = spInstance.attest(attestation, "", "", "");
        if (attestationId == 0) revert AttestationFailed();

        shipmentConfirmed = true;
        emit ShipmentConfirmed(shipper, attestationId);
    }

    function confirmReceipt(bytes memory data) external {
        if (_msgSender() != customer) revert NotAuthorized();
        if (!shipmentConfirmed || receiptConfirmed) revert InvalidState();

        bytes[] memory recipients = new bytes[](2);
        recipients[0] = abi.encode(customer);
        recipients[1] = abi.encode(shipper);

        Attestation memory attestation = Attestation({
            schemaId: schemaId,
            linkedAttestationId: 0,
            attestTimestamp: uint64(block.timestamp), // Corrected casting
            revokeTimestamp: 0,
            attester: address(this),
            validUntil: 0,
            dataLocation: DataLocation.ONCHAIN,
            revoked: false,
            recipients: recipients,
            data: data
        });

        uint64 attestationId = spInstance.attest(attestation, "", "", "");
        if (attestationId == 0) revert AttestationFailed();

        receiptConfirmed = true;
        emit ReceiptConfirmed(customer, attestationId);
        _releaseFunds();
    }

    function _releaseFunds() internal {
        require(shipmentConfirmed && receiptConfirmed, "Conditions not met for release");
        (bool success, ) = shipper.call{value: amount}("");
        require(success, "Transfer failed");
        emit FundsReleased(shipper, amount);
    }

    function cancelEscrow() external onlyOwner {
        require(!shipmentConfirmed && !receiptConfirmed, "Cannot cancel after confirmations");
        (bool success, ) = customer.call{value: address(this).balance}("");
        require(success, "Refund failed");
        resetEscrow();
    }

    function resetEscrow() internal {
        customer = address(0);
        shipper = address(0);
        amount = 0;
        shipmentConfirmed = false;
        receiptConfirmed = false;
    }
}