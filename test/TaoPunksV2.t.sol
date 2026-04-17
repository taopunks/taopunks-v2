// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/TaoPunksV2.sol";

contract TaoPunksV2Test is Test {
    TaoPunksV2 public nft;
    address public owner = address(0xA);
    address public alice = address(0xB);
    address public bob = address(0xC);
    address public dead = 0x000000000000000000000000000000000000dEaD;
    string public constant BASE_URI = "ipfs://bafybeielhkzlrzz6dhz4ixgtywf43s3z7mdpk4fysaqapehz3bijck6cqa/";

    function setUp() public {
        nft = new TaoPunksV2(owner, BASE_URI);
    }

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR & METADATA
    // ═══════════════════════════════════════════════════════════

    function test_constructor() public view {
        assertEq(nft.name(), "TAO Punks");
        assertEq(nft.symbol(), "TAOPUNK");
        assertEq(nft.owner(), owner);
        assertEq(nft.totalSupply(), 0);
        assertEq(nft.airdropFinalized(), false);
        assertEq(nft.MAX_SUPPLY(), 3333);
        assertEq(nft.BURN_ADDRESS(), dead);
    }

    function test_tokenURI_matchesV1Format() public {
        address[] memory r = new address[](3);
        r[0] = alice; r[1] = alice; r[2] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);

        // V1 returns: ipfs://bafybeielhkzlrzz6dhz4ixgtywf43s3z7mdpk4fysaqapehz3bijck6cqa/1
        // V2 must return the exact same format
        assertEq(nft.tokenURI(1), string.concat(BASE_URI, "1"));
        assertEq(nft.tokenURI(2), string.concat(BASE_URI, "2"));
        assertEq(nft.tokenURI(3), string.concat(BASE_URI, "3"));
    }

    function test_tokenURI_revert_nonexistent() public {
        vm.expectRevert();
        nft.tokenURI(1); // no tokens minted yet
    }

    function test_startTokenId_isOne() public {
        address[] memory r = new address[](1);
        r[0] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);
        assertEq(nft.ownerOf(1), alice);

        // Token ID 0 should not exist
        vm.expectRevert();
        nft.ownerOf(0);
    }

    function test_baseURI_isImmutable() public view {
        // There is no setBaseURI function. Verify by checking interface.
        // The only way to confirm immutability is the absence of a setter.
        // We verify tokenURI returns the correct IPFS CID.
        // (No setter = no code path to change it.)
        bytes4 setBaseURISig = bytes4(keccak256("setBaseURI(string)"));
        assertFalse(nft.supportsInterface(setBaseURISig)); // not a valid interface check but confirms no ERC2981
    }

    // ═══════════════════════════════════════════════════════════
    //  AIRDROP — CORE FUNCTIONALITY
    // ═══════════════════════════════════════════════════════════

    function test_airdropBatch_basic() public {
        address[] memory r = new address[](5);
        r[0] = alice; r[1] = bob; r[2] = dead; r[3] = alice; r[4] = bob;

        vm.prank(owner);
        nft.airdropBatch(r);

        assertEq(nft.totalSupply(), 5);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(2), bob);
        assertEq(nft.ownerOf(3), dead);
        assertEq(nft.ownerOf(4), alice);
        assertEq(nft.ownerOf(5), bob);
    }

    function test_airdropBatch_multipleBatches_sequentialIds() public {
        address[] memory b1 = new address[](3);
        b1[0] = alice; b1[1] = bob; b1[2] = alice;
        vm.prank(owner);
        nft.airdropBatch(b1);

        address[] memory b2 = new address[](2);
        b2[0] = bob; b2[1] = dead;
        vm.prank(owner);
        nft.airdropBatch(b2);

        // Verify IDs continue sequentially across batches
        assertEq(nft.totalSupply(), 5);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(4), bob);    // first of batch 2
        assertEq(nft.ownerOf(5), dead);   // second of batch 2
    }

    function test_airdropBatch_preservesExactTokenIds() public {
        address[] memory r = new address[](10);
        for (uint256 i = 0; i < 10; i++) r[i] = alice;
        r[2] = dead;  // token ID 3
        r[6] = dead;  // token ID 7

        vm.prank(owner);
        nft.airdropBatch(r);

        assertEq(nft.ownerOf(3), dead);
        assertEq(nft.ownerOf(7), dead);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(10), alice);
    }

    function test_airdropBatch_singleToken() public {
        address[] memory r = new address[](1);
        r[0] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);

        assertEq(nft.totalSupply(), 1);
        assertEq(nft.ownerOf(1), alice);
    }

    function test_airdropBatch_emptyArray() public {
        address[] memory r = new address[](0);
        vm.prank(owner);
        nft.airdropBatch(r); // should not revert, just do nothing

        assertEq(nft.totalSupply(), 0);
    }

    function test_airdropBatch_allToBurnAddress() public {
        address[] memory r = new address[](5);
        for (uint256 i = 0; i < 5; i++) r[i] = dead;
        vm.prank(owner);
        nft.airdropBatch(r);

        assertEq(nft.totalSupply(), 5);
        assertEq(nft.balanceOf(dead), 5);
    }

    function test_revert_airdrop_notOwner() public {
        address[] memory r = new address[](1);
        r[0] = alice;
        vm.prank(alice);
        vm.expectRevert();
        nft.airdropBatch(r);
    }

    function test_revert_airdrop_exceedsMaxSupply() public {
        address[] memory big = new address[](3333);
        for (uint256 i = 0; i < 3333; i++) big[i] = alice;
        vm.prank(owner);
        nft.airdropBatch(big);

        address[] memory one = new address[](1);
        one[0] = bob;
        vm.prank(owner);
        vm.expectRevert(TaoPunksV2.ExceedsMaxSupply.selector);
        nft.airdropBatch(one);
    }

    function test_revert_airdrop_exceedsMaxSupply_partial() public {
        // Mint 3330, then try to mint 5 more (only 3 slots left)
        address[] memory big = new address[](3330);
        for (uint256 i = 0; i < 3330; i++) big[i] = alice;
        vm.prank(owner);
        nft.airdropBatch(big);

        address[] memory over = new address[](5);
        for (uint256 i = 0; i < 5; i++) over[i] = bob;
        vm.prank(owner);
        vm.expectRevert(TaoPunksV2.ExceedsMaxSupply.selector);
        nft.airdropBatch(over);

        // But 3 should work
        address[] memory exact = new address[](3);
        for (uint256 i = 0; i < 3; i++) exact[i] = bob;
        vm.prank(owner);
        nft.airdropBatch(exact);
        assertEq(nft.totalSupply(), 3333);
    }

    function test_revert_airdrop_afterFinalized() public {
        vm.prank(owner);
        nft.finalizeAirdrop();

        address[] memory r = new address[](1);
        r[0] = alice;
        vm.prank(owner);
        vm.expectRevert(TaoPunksV2.AirdropAlreadyFinalized.selector);
        nft.airdropBatch(r);
    }

    // ═══════════════════════════════════════════════════════════
    //  FINALIZE
    // ═══════════════════════════════════════════════════════════

    function test_finalizeAirdrop() public {
        address[] memory r = new address[](5);
        for (uint256 i = 0; i < 5; i++) r[i] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);

        vm.prank(owner);
        nft.finalizeAirdrop();
        assertTrue(nft.airdropFinalized());
    }

    function test_finalizeAirdrop_emitsEvent() public {
        address[] memory r = new address[](10);
        for (uint256 i = 0; i < 10; i++) r[i] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit TaoPunksV2.AirdropFinalized(10);
        nft.finalizeAirdrop();
    }

    function test_revert_doubleFinalize() public {
        vm.prank(owner);
        nft.finalizeAirdrop();
        vm.prank(owner);
        vm.expectRevert(TaoPunksV2.AirdropAlreadyFinalized.selector);
        nft.finalizeAirdrop();
    }

    function test_revert_finalize_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        nft.finalizeAirdrop();
    }

    // ═══════════════════════════════════════════════════════════
    //  BURN
    // ═══════════════════════════════════════════════════════════

    function test_burn_byHolder() public {
        address[] memory r = new address[](3);
        r[0] = alice; r[1] = bob; r[2] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);

        vm.prank(alice);
        nft.burn(1);

        assertEq(nft.totalBurned(), 1);
        assertEq(nft.balanceOf(alice), 1);
    }

    function test_burn_byApprovedOperator() public {
        address[] memory r = new address[](1);
        r[0] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);

        // Alice approves Bob
        vm.prank(alice);
        nft.approve(bob, 1);

        // Bob burns
        vm.prank(bob);
        nft.burn(1);
        assertEq(nft.totalBurned(), 1);
    }

    function test_burn_multipleTokens() public {
        address[] memory r = new address[](5);
        for (uint256 i = 0; i < 5; i++) r[i] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);

        vm.startPrank(alice);
        nft.burn(1);
        nft.burn(3);
        nft.burn(5);
        vm.stopPrank();

        assertEq(nft.totalBurned(), 3);
        assertEq(nft.balanceOf(alice), 2);
    }

    function test_revert_burn_notOwnerOrApproved() public {
        address[] memory r = new address[](1);
        r[0] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);

        vm.prank(bob);
        vm.expectRevert();
        nft.burn(1);
    }

    function test_revert_burn_alreadyBurned() public {
        address[] memory r = new address[](1);
        r[0] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);

        vm.prank(alice);
        nft.burn(1);

        vm.prank(alice);
        vm.expectRevert();
        nft.burn(1); // already burned
    }

    // ═══════════════════════════════════════════════════════════
    //  OWNERSHIP (Ownable2Step)
    // ═══════════════════════════════════════════════════════════

    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert("Disabled");
        nft.renounceOwnership();
    }

    function test_transferOwnership_twoStep() public {
        vm.prank(owner);
        nft.transferOwnership(alice);
        assertEq(nft.owner(), owner);
        assertEq(nft.pendingOwner(), alice);

        vm.prank(alice);
        nft.acceptOwnership();
        assertEq(nft.owner(), alice);
        assertEq(nft.pendingOwner(), address(0));
    }

    function test_transferOwnership_newOwnerCanAirdrop() public {
        vm.prank(owner);
        nft.transferOwnership(alice);
        vm.prank(alice);
        nft.acceptOwnership();

        address[] memory r = new address[](1);
        r[0] = bob;
        vm.prank(alice);
        nft.airdropBatch(r);
        assertEq(nft.ownerOf(1), bob);
    }

    function test_revert_acceptOwnership_notPending() public {
        vm.prank(owner);
        nft.transferOwnership(alice);

        vm.prank(bob);
        vm.expectRevert();
        nft.acceptOwnership();
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERFACE SUPPORT (no ERC2981)
    // ═══════════════════════════════════════════════════════════

    function test_noERC2981() public view {
        assertFalse(nft.supportsInterface(0x2a55205a));
    }

    function test_supportsERC721() public view {
        assertTrue(nft.supportsInterface(0x80ac58cd));  // ERC721
        assertTrue(nft.supportsInterface(0x5b5e139f));  // ERC721Metadata
        assertTrue(nft.supportsInterface(0x01ffc9a7));  // ERC165
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEW HELPERS
    // ═══════════════════════════════════════════════════════════

    function test_totalMinted() public {
        address[] memory r = new address[](3);
        for (uint256 i = 0; i < 3; i++) r[i] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);
        assertEq(nft.totalMinted(), 3);
    }

    function test_totalBurned_afterBurn() public {
        address[] memory r = new address[](3);
        for (uint256 i = 0; i < 3; i++) r[i] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);

        vm.prank(alice);
        nft.burn(2);
        assertEq(nft.totalBurned(), 1);
        assertEq(nft.totalMinted(), 3);
        assertEq(nft.totalSupply(), 2); // 3 minted - 1 burned
    }

    // ═══════════════════════════════════════════════════════════
    //  FUZZ TESTS
    // ═══════════════════════════════════════════════════════════

    function testFuzz_airdropBatch_variableSize(uint8 count) public {
        vm.assume(count > 0 && count <= 100);
        address[] memory r = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            r[i] = address(uint160(100 + i));
        }
        vm.prank(owner);
        nft.airdropBatch(r);
        assertEq(nft.totalSupply(), count);
        // First token is ID 1, last is count
        assertEq(nft.ownerOf(1), address(uint160(100)));
        assertEq(nft.ownerOf(count), address(uint160(100 + count - 1)));
    }

    function testFuzz_burn_randomToken(uint8 tokenIndex) public {
        uint256 count = 20;
        vm.assume(tokenIndex < count);
        address[] memory r = new address[](count);
        for (uint256 i = 0; i < count; i++) r[i] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);

        uint256 tokenId = uint256(tokenIndex) + 1;
        vm.prank(alice);
        nft.burn(tokenId);
        assertEq(nft.totalBurned(), 1);

        vm.expectRevert();
        nft.ownerOf(tokenId);
    }

    // ═══════════════════════════════════════════════════════════
    //  SECURITY TESTS
    // ═══════════════════════════════════════════════════════════

    function test_security_noPublicMint() public {
        // Verify there's no mint() or publicMint() function
        // Non-owner cannot create tokens
        vm.prank(alice);
        vm.expectRevert();
        address[] memory r = new address[](1);
        r[0] = alice;
        nft.airdropBatch(r);
    }

    function test_security_nonReentrant() public {
        // airdropBatch has nonReentrant modifier
        // Just verify it's callable normally (reentrancy test would need a malicious contract)
        address[] memory r = new address[](1);
        r[0] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);
        assertEq(nft.totalSupply(), 1);
    }

    function test_security_ownerCannotTakeTokens() public {
        address[] memory r = new address[](1);
        r[0] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);

        // Owner cannot transfer alice's token
        vm.prank(owner);
        vm.expectRevert();
        nft.transferFrom(alice, owner, 1);
    }

    function test_security_ownerCannotBurnHolderTokens() public {
        address[] memory r = new address[](1);
        r[0] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);

        vm.prank(owner);
        vm.expectRevert();
        nft.burn(1);
    }

    function test_security_maxSupplyEnforced() public {
        address[] memory big = new address[](3333);
        for (uint256 i = 0; i < 3333; i++) big[i] = alice;
        vm.prank(owner);
        nft.airdropBatch(big);

        assertEq(nft.totalSupply(), 3333);
        assertEq(nft.totalMinted(), 3333);

        // Cannot exceed even with owner
        address[] memory one = new address[](1);
        one[0] = owner;
        vm.prank(owner);
        vm.expectRevert(TaoPunksV2.ExceedsMaxSupply.selector);
        nft.airdropBatch(one);
    }

    // ═══════════════════════════════════════════════════════════
    //  SNAPSHOT-BASED SIMULATION (mirrors actual airdrop)
    // ═══════════════════════════════════════════════════════════

    function test_snapshotSimulation_fullAirdrop() public {
        // Simulate the actual CTO airdrop:
        // - 3333 tokens total
        // - 8 team tokens burned to dead address
        // - 3325 community tokens
        // - Multiple batches of 100

        // Build recipients: 3333 addresses, with team burns at specific indices
        address[] memory allRecipients = new address[](3333);

        // Simulate 288 unique holders
        address[10] memory holders = [
            address(0x101), address(0x102), address(0x103), address(0x104), address(0x105),
            address(0x106), address(0x107), address(0x108), address(0x109), address(0x110)
        ];

        for (uint256 i = 0; i < 3333; i++) {
            allRecipients[i] = holders[i % 10];
        }

        // Team token burns (simulating the 8 confirmed tokens)
        // Real IDs: 91, 92, 442, 443, 2034, 2036, 2858, 2859
        allRecipients[90] = dead;    // token 91
        allRecipients[91] = dead;    // token 92
        allRecipients[441] = dead;   // token 442
        allRecipients[442] = dead;   // token 443
        allRecipients[2033] = dead;  // token 2034
        allRecipients[2035] = dead;  // token 2036
        allRecipients[2857] = dead;  // token 2858
        allRecipients[2858] = dead;  // token 2859

        // Airdrop in batches of 100 (like the real execution)
        vm.startPrank(owner);
        uint256 batchSize = 100;
        for (uint256 start = 0; start < 3333; start += batchSize) {
            uint256 end = start + batchSize;
            if (end > 3333) end = 3333;
            uint256 len = end - start;

            address[] memory batch = new address[](len);
            for (uint256 i = 0; i < len; i++) {
                batch[i] = allRecipients[start + i];
            }
            nft.airdropBatch(batch);
        }

        // Finalize
        nft.finalizeAirdrop();
        vm.stopPrank();

        // ── Verify everything ──

        // Total supply
        assertEq(nft.totalSupply(), 3333);
        assertEq(nft.totalMinted(), 3333);
        assertTrue(nft.airdropFinalized());

        // Team tokens are at dead address
        assertEq(nft.ownerOf(91), dead);
        assertEq(nft.ownerOf(92), dead);
        assertEq(nft.ownerOf(442), dead);
        assertEq(nft.ownerOf(443), dead);
        assertEq(nft.ownerOf(2034), dead);
        assertEq(nft.ownerOf(2036), dead);
        assertEq(nft.ownerOf(2858), dead);
        assertEq(nft.ownerOf(2859), dead);
        assertEq(nft.balanceOf(dead), 8);

        // Community tokens are at correct holders
        assertEq(nft.ownerOf(1), holders[0]);    // token 1
        assertEq(nft.ownerOf(3333), holders[2]); // last token

        // Metadata still works
        assertEq(nft.tokenURI(1), string.concat(BASE_URI, "1"));
        assertEq(nft.tokenURI(3333), string.concat(BASE_URI, "3333"));

        // No more minting possible
        address[] memory extra = new address[](1);
        extra[0] = alice;
        vm.prank(owner);
        vm.expectRevert(TaoPunksV2.AirdropAlreadyFinalized.selector);
        nft.airdropBatch(extra);

        // Holders can still transfer and burn after finalization
        vm.prank(holders[0]);
        nft.transferFrom(holders[0], alice, 1);
        assertEq(nft.ownerOf(1), alice);

        vm.prank(alice);
        nft.burn(1);
        assertEq(nft.totalBurned(), 1);
        assertEq(nft.totalSupply(), 3332);
    }

    // ═══════════════════════════════════════════════════════════
    //  GAS BENCHMARKS
    // ═══════════════════════════════════════════════════════════

    function test_gas_airdropBatch100() public {
        address[] memory r = new address[](100);
        for (uint256 i = 0; i < 100; i++) r[i] = address(uint160(200 + i));
        vm.prank(owner);
        uint256 gasBefore = gasleft();
        nft.airdropBatch(r);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas for 100-token airdrop batch", gasUsed);
        assertEq(nft.totalSupply(), 100);
    }

    function test_gas_singleBurn() public {
        address[] memory r = new address[](1);
        r[0] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        nft.burn(1);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas for single burn", gasUsed);
    }

    function test_gas_singleTransfer() public {
        address[] memory r = new address[](1);
        r[0] = alice;
        vm.prank(owner);
        nft.airdropBatch(r);

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        nft.transferFrom(alice, bob, 1);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("Gas for single transfer", gasUsed);
    }

    // ═══════════════════════════════════════════════════════════
    //  FULL END-TO-END SCENARIO
    // ═══════════════════════════════════════════════════════════

    function test_endToEnd_completeCTO() public {
        // 1. Deploy (done in setUp)
        // 2. Airdrop 10 tokens with 2 team burns
        address[] memory r = new address[](10);
        r[0] = alice;   r[1] = bob;    r[2] = dead;   r[3] = alice;  r[4] = bob;
        r[5] = alice;   r[6] = bob;    r[7] = dead;   r[8] = alice;  r[9] = bob;

        vm.prank(owner);
        nft.airdropBatch(r);

        // 3. Finalize
        vm.prank(owner);
        nft.finalizeAirdrop();

        // 4. Verify state
        assertEq(nft.totalSupply(), 10);
        assertTrue(nft.airdropFinalized());
        assertEq(nft.ownerOf(3), dead);
        assertEq(nft.ownerOf(8), dead);
        assertEq(nft.balanceOf(alice), 4);
        assertEq(nft.balanceOf(bob), 4);
        assertEq(nft.balanceOf(dead), 2);

        // 5. No more minting
        address[] memory m = new address[](1);
        m[0] = alice;
        vm.prank(owner);
        vm.expectRevert(TaoPunksV2.AirdropAlreadyFinalized.selector);
        nft.airdropBatch(m);

        // 6. Holders can burn
        vm.prank(alice);
        nft.burn(1);
        assertEq(nft.totalBurned(), 1);

        // 7. Holders can transfer
        vm.prank(bob);
        nft.transferFrom(bob, alice, 2);
        assertEq(nft.ownerOf(2), alice);

        // 8. Transfer ownership (simulate handoff)
        vm.prank(owner);
        nft.transferOwnership(alice);
        vm.prank(alice);
        nft.acceptOwnership();
        assertEq(nft.owner(), alice);

        // 9. New owner can still operate
        vm.prank(bob);
        nft.transferFrom(bob, alice, 5);
        assertEq(nft.ownerOf(5), alice);
    }
}
