import { ethers } from "ethers";

// Contract ABIs (simplified for example)
const FACTORY_ABI = [
	"function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool)",
	"function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address)",
];

const POOL_ABI = [
	"function initialize(uint160 sqrtPriceX96) external",
	"function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)",
];

// Configuration
const FACTORY_ADDRESS = "0x..."; // Replace with actual address
const WETH_ADDRESS = "0x...";
const USDC_ADDRESS = "0x...";

async function main() {
	// Connect to provider
	const provider = new ethers.JsonRpcProvider("http://localhost:8545");
	const signer = await provider.getSigner();

	console.log("Creating pool...");
	console.log("Signer address:", await signer.getAddress());

	// Connect to factory
	const factory = new ethers.Contract(FACTORY_ADDRESS, FACTORY_ABI, signer);

	// Create pool with 0.3% fee
	const fee = 3000; // 0.3% = 3000 basis points

	try {
		// Check if pool already exists
		const existingPool = await factory.getPool(WETH_ADDRESS, USDC_ADDRESS, fee);

		if (existingPool !== ethers.ZeroAddress) {
			console.log("Pool already exists at:", existingPool);
			return;
		}

		// Create new pool
		const tx = await factory.createPool(WETH_ADDRESS, USDC_ADDRESS, fee);
		console.log("Transaction hash:", tx.hash);

		// Wait for confirmation
		const receipt = await tx.wait();
		console.log("Pool created! Gas used:", receipt.gasUsed.toString());

		// Get pool address
		const poolAddress = await factory.getPool(WETH_ADDRESS, USDC_ADDRESS, fee);
		console.log("Pool address:", poolAddress);

		// Initialize pool at 1:1 price (for demonstration)
		const pool = new ethers.Contract(poolAddress, POOL_ABI, signer);

		// sqrtPriceX96 = sqrt(price) * 2^96
		// For 1:1 price: sqrt(1) * 2^96
		const sqrtPriceX96 = "79228162514264337593543950336";

		const initTx = await pool.initialize(sqrtPriceX96);
		console.log("Initializing pool...");

		await initTx.wait();
		console.log("Pool initialized!");

		// Verify initialization
		const slot0 = await pool.slot0();
		console.log("Current price:", slot0.sqrtPriceX96.toString());
		console.log("Current tick:", slot0.tick);
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
