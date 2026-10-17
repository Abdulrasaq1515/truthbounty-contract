// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../contracts/libraries/BoundedSafeERC20.sol";
import "../contracts/MockERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BoundedERC20Harness {
    using BoundedSafeERC20 for IERC20;

    function transfer(IERC20 token, address recipient, uint256 amount) external {
        token.safeTransfer(recipient, amount);
    }
}

contract NoReturnERC20Mock {
    fallback() external {
        assembly {
            return(0, 0)
        }
    }
}

contract FalseReturnERC20Mock {
    fallback() external {
        assembly {
            mstore(0, 0)
            return(0, 0x20)
        }
    }
}

contract ShortReturnERC20Mock {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 1)
        }
    }
}

contract LargeReturnERC20Mock {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 0x10000)
        }
    }
}

contract LargeRevertERC20Mock {
    fallback() external {
        assembly {
            mstore(0, 0x12345678)
            revert(0, 0x10000)
        }
    }
}

contract BoundedSafeERC20Test is Test {
    BoundedERC20Harness internal harness;
    address internal constant RECIPIENT = address(0xBEEF);

    function setUp() public {
        harness = new BoundedERC20Harness();
    }

    function test_standardERC20TransferRemainsCompatible() public {
        MockERC20 token = new MockERC20("Standard", "STD");
        token.mint(address(harness), 10);

        harness.transfer(IERC20(address(token)), RECIPIENT, 4);

        assertEq(token.balanceOf(RECIPIENT), 4);
    }

    function test_noReturnTokenRemainsCompatible() public {
        harness.transfer(IERC20(address(new NoReturnERC20Mock())), RECIPIENT, 1);
    }

    function test_falseAndMalformedReturnDataFailWithStableError() public {
        address falseToken = address(new FalseReturnERC20Mock());
        vm.expectRevert(
            abi.encodeWithSelector(BoundedSafeERC20.SafeERC20FailedOperation.selector, falseToken)
        );
        harness.transfer(IERC20(falseToken), RECIPIENT, 1);

        address shortToken = address(new ShortReturnERC20Mock());
        vm.expectRevert(
            abi.encodeWithSelector(BoundedSafeERC20.SafeERC20FailedOperation.selector, shortToken)
        );
        harness.transfer(IERC20(shortToken), RECIPIENT, 1);
    }

    function test_largeSuccessfulReturndataCopiesOnlyOneWord() public {
        address token = address(new LargeReturnERC20Mock());
        uint256 gasBefore = gasleft();

        harness.transfer(IERC20(token), RECIPIENT, 1);

        assertLt(gasBefore - gasleft(), 300_000);
    }

    function test_largeRevertDataBecomesStableBoundedError() public {
        address token = address(new LargeRevertERC20Mock());
        uint256 gasBefore = gasleft();

        vm.expectRevert(abi.encodeWithSelector(BoundedSafeERC20.SafeERC20FailedOperation.selector, token));
        harness.transfer(IERC20(token), RECIPIENT, 1);

        assertLt(gasBefore - gasleft(), 300_000);
    }
}
