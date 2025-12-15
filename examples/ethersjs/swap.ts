import { ethers } from "ethers";

// Contract ABIs
const ROUTER_ABI = [
	"function exactInputSingle((address tokenIn, address tokenOut, uint24 fee, address recipient, uint256 amountIn, uint256 amountOutMinimum, uint160 sqrtPriceLimitX96)) external payable returns (uint256 amountOut)",
];

const ERC20_ABI = [
	"function approve(address spender, uint256 amount) external returns (bool)",
	"function balanceOf(address account) external view returns (uint256)",
	"function decimals() external view returns (uint8)",
];

// Configuration
const ROUTER_ADDRESS = "0x..."; // Replace with actual address
const TOKEN_IN = "0x..."; // WETH
const TOKEN_OUT = "0x..."; // USDC

async function main() {
	// Connect to provider
	const provider = new ethers.JsonRpcProvider("http://localhost:8545");
	const signer = await provider.getSigner();
	const signerAddress = await signer.getAddress();

	console.log("Executing swap...");
	console.log("Signer:", signerAddress);

	// Connect to contracts
	const router = new ethers.Contract(ROUTER_ADDRESS, ROUTER_ABI, signer);
	const tokenIn = new ethers.Contract(TOKEN_IN, ERC20_ABI, signer);
	const tokenOut = new ethers.Contract(TOKEN_OUT, ERC20_ABI, signer);

	// Get token decimals
	const decimalsIn = await tokenIn.decimals();
	const decimalsOut = await tokenOut.decimals();

	// Swap parameters
	const amountIn = ethers.parseUnits("1", decimalsIn); // 1 token
	const minAmountOut = ethers.parseUnits("1400", decimalsOut); // Minimum 1400 tokens out
	const fee = 3000; // 0.3%

	try {
		// Check balances before
		const balanceInBefore = await tokenIn.balanceOf(signerAddress);
		const balanceOutBefore = await tokenOut.balanceOf(signerAddress);

		console.log("Balance before:");
		console.log("  Token In:", ethers.formatUnits(balanceInBefore, decimalsIn));
		console.log(
			"  Token Out:",
			ethers.formatUnits(balanceOutBefore, decimalsOut)
		);

		// Approve router to spend tokens
		console.log("Approving router...");
		const approveTx = await tokenIn.approve(ROUTER_ADDRESS, amountIn);
		await approveTx.wait();
		console.log("Approved!");

		// Execute swap
		console.log("Swapping...");
		const swapParams = {
			tokenIn: TOKEN_IN,
			tokenOut: TOKEN_OUT,
			fee: fee,
			recipient: signerAddress,
			amountIn: amountIn,
			amountOutMinimum: minAmountOut,
			sqrtPriceLimitX96: 0, // No price limit
		};

		const tx = await router.exactInputSingle(swapParams);
		console.log("Transaction hash:", tx.hash);

		// Wait for confirmation
		const receipt = await tx.wait();
		console.log("Swap executed! Gas used:", receipt.gasUsed.toString());

		// Check balances after
		const balanceInAfter = await tokenIn.balanceOf(signerAddress);
		const balanceOutAfter = await tokenOut.balanceOf(signerAddress);

		console.log("Balance after:");
		console.log("  Token In:", ethers.formatUnits(balanceInAfter, decimalsIn));
		console.log("  Token Out:", ethers.formatUnits(balanceOutAfter, decimalsOut));

		// Calculate amounts
		const amountInUsed = balanceInBefore - balanceInAfter;
		const amountOutReceived = balanceOutAfter - balanceOutBefore;

		console.log("Swap summary:");
		console.log("  Amount In:", ethers.formatUnits(amountInUsed, decimalsIn));
		console.log(
			"  Amount Out:",
			ethers.formatUnits(amountOutReceived, decimalsOut)
		);
		console.log(
			"  Price:",
			(Number(amountOutReceived) / Number(amountInUsed)).toFixed(2)
		);
	} catch (error) {
		console.error("Error:", error);
	}
}

main()
	.then(() => process.exit(0))
	.catch((error) => {
		console.error(error);
		process.exit(1);
	});
