#!/usr/bin/env node

/**
 * Script to calculate required swap amounts and save 1inch swap data for current block
 *
 * This script:
 * 1. Fetches the current Ethereum block number (or uses provided block)
 * 2. Runs forge tests to calculate borrowAmount and flashLoanAmount at that block
 * 3. Fetches 1inch swap data for those amounts
 * 4. Saves everything to test/fixtures/
 *
 * Usage: node test/scripts/calculate_and_save_swap_data.js [optional-block-number]
 */

const { execSync } = require("child_process");
const https = require("https");
const fs = require("fs");
const path = require("path");

const CHAIN_ID = 1; // Ethereum mainnet

// Load .env file manually
function loadEnvFile() {
  try {
    const envPath = path.join(__dirname, "..", "..", ".env");
    const envContent = fs.readFileSync(envPath, "utf8");
    envContent.split("\n").forEach((line) => {
      const match = line.match(/^([^=:#]+)=(.*)$/);
      if (match) {
        const key = match[1].trim();
        const value = match[2].trim().replace(/^["']|["']$/g, "");
        process.env[key] = value;
      }
    });
  } catch (e) {
    // .env file not found
  }
}
loadEnvFile();

const API_KEY = process.env.ONE_INCH_API_KEY || process.env.INCH_API_KEY;
if (!API_KEY) {
  console.error("Error: ONE_INCH_API_KEY environment variable not set");
  process.exit(1);
}

const ETH_RPC_URL = process.env.ETH_RPC_URL;
if (!ETH_RPC_URL) {
  console.error("Error: ETH_RPC_URL environment variable not set");
  process.exit(1);
}

function getCurrentBlockNumber() {
  return new Promise((resolve, reject) => {
    const url = new URL(ETH_RPC_URL);
    const postData = JSON.stringify({
      jsonrpc: "2.0",
      method: "eth_blockNumber",
      params: [],
      id: 1,
    });

    const options = {
      hostname: url.hostname,
      port: url.port || (url.protocol === "https:" ? 443 : 80),
      path: url.pathname + url.search,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(postData),
      },
    };

    const protocol = url.protocol === "https:" ? https : require("http");
    const req = protocol.request(options, (res) => {
      let data = "";

      res.on("data", (chunk) => {
        data += chunk;
      });

      res.on("end", () => {
        try {
          const json = JSON.parse(data);
          const blockHex = json.result;
          const blockNumber = parseInt(blockHex, 16);
          resolve(blockNumber);
        } catch (e) {
          reject(e);
        }
      });
    });

    req.on("error", (e) => {
      reject(e);
    });

    req.write(postData);
    req.end();
  });
}

// Token addresses
const WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";

function getSymbol(address) {
  if (address.toLowerCase() === WETH.toLowerCase()) return "WETH";
  if (address.toLowerCase() === USDC.toLowerCase()) return "USDC";
  return address;
}

function fetch1inchSwap(fromToken, toToken, amount) {
  return new Promise((resolve, reject) => {
    const fromAddress = "0x0000000000000000000000000000000000000000";
    const url = `https://api.1inch.dev/swap/v6.0/${CHAIN_ID}/swap?src=${fromToken}&dst=${toToken}&amount=${amount}&from=${fromAddress}&slippage=5&disableEstimate=true`;

    const options = {
      headers: {
        Authorization: `Bearer ${API_KEY}`,
        Accept: "application/json",
      },
    };

    https
      .get(url, options, (res) => {
        let data = "";

        res.on("data", (chunk) => {
          data += chunk;
        });

        res.on("end", () => {
          if (res.statusCode !== 200) {
            reject(new Error(`HTTP ${res.statusCode}: ${data}`));
            return;
          }

          try {
            const json = JSON.parse(data);
            resolve({
              fromToken,
              toToken,
              fromAmount: amount,
              toAmount: json.toAmount,
              swapData: json.tx.data,
            });
          } catch (e) {
            reject(e);
          }
        });
      })
      .on("error", (e) => {
        reject(e);
      });
  });
}

async function recordSwapData(blockNumber) {
  console.log(
    `\n1. Running tests to record actual swap data at block ${blockNumber}...`,
  );

  try {
    // Run the forge test that will fetch real swap data
    const output = execSync(
      `forge test --match-contract RecordSwapData --match-test test_RecordActualSwapData --match-path test/scripts/RecordSwapData.t.sol --fork-url ${ETH_RPC_URL} --fork-block-number ${blockNumber} -vv`,
      { encoding: "utf8", cwd: path.join(__dirname, "..", "..") },
    );

    // Parse the block number
    const blockMatch = output.match(/BLOCK_NUMBER: (\d+)/);
    if (!blockMatch) {
      throw new Error("Could not parse block number from test output");
    }
    const actualBlock = blockMatch[1];

    // Parse all swap data entries
    const swaps = {};
    const swapRegex =
      /SWAP_START\s+KEY: (\S+)\s+FROM_TOKEN: (0x[a-fA-F0-9]+)\s+TO_TOKEN: (0x[a-fA-F0-9]+)\s+FROM_AMOUNT: (\d+)\s+SWAP_DATA: (0x[a-fA-F0-9]+)\s+SWAP_END/g;

    let match;
    while ((match = swapRegex.exec(output)) !== null) {
      const [, key, fromToken, toToken, fromAmount, swapData] = match;
      swaps[key] = {
        fromToken,
        toToken,
        fromAmount,
        swapData,
      };
      console.log(`  ✓ Recorded ${key}`);
    }

    if (Object.keys(swaps).length === 0) {
      console.error("\nForge output:");
      console.error(output);
      throw new Error("No swap data found in test output");
    }

    return { blockNumber: actualBlock, swaps };
  } catch (error) {
    throw new Error(`Failed to record swap data: ${error.message}`);
  }
}

async function saveSwapData(blockNumber) {
  const { blockNumber: actualBlock, swaps } = await recordSwapData(blockNumber);

  console.log("\n2. Saving swap data...");

  const output = {
    blockNumber: parseInt(actualBlock),
    swaps,
  };

  const fixturesDir = path.join(__dirname, "..", "fixtures");
  if (!fs.existsSync(fixturesDir)) {
    fs.mkdirSync(fixturesDir, { recursive: true });
  }

  const outputPath = path.join(
    fixturesDir,
    `swap_data_block_${actualBlock}.json`,
  );
  fs.writeFileSync(outputPath, JSON.stringify(output, null, 2));

  console.log(`\n✓ Swap data saved to: ${outputPath}`);
  console.log(
    `\nRecorded ${Object.keys(swaps).length} swaps for block ${actualBlock}`,
  );
  console.log(
    `\nTo use in tests, update SAVED_DATA_BLOCK in test/fork/Stratax.t.sol to ${actualBlock}`,
  );
  console.log(`Then run: forge test --match-contract StrataxForkTest -vv`);
}

async function main() {
  let blockNumber = process.argv[2];

  if (!blockNumber) {
    console.log("Fetching current Ethereum block number...");
    blockNumber = await getCurrentBlockNumber();
    console.log(`Current block: ${blockNumber}\n`);
  } else {
    blockNumber = parseInt(blockNumber);
    console.log(`Using specified block: ${blockNumber}\n`);
  }

  await saveSwapData(blockNumber);
}

main().catch((error) => {
  console.error("Error:", error.message);
  process.exit(1);
});
