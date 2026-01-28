#!/usr/bin/env node
/**
 * Script to fetch 1inch swap data for testing
 * Usage: node get_1inch_swap.js <fromToken> <toToken> <amount> <fromAddress>
 */

const https = require("https");
const { URL } = require("url");
const fs = require("fs");
const path = require("path");

// Load .env file manually to avoid dotenv output messages
function loadEnvFile() {
  try {
    const envPath = path.join(__dirname, "..", ".env");
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
    // .env file not found or couldn't be read
  }
}
loadEnvFile();

async function get1inchSwapData(
  fromToken,
  toToken,
  amount,
  fromAddress,
  chainId = 1,
) {
  const baseUrl = `https://api.1inch.dev/swap/v6.0/${chainId}/swap`;

  const params = new URLSearchParams({
    src: fromToken,
    dst: toToken,
    amount: amount,
    from: fromAddress,
    slippage: "1", // 1% slippage
    disableEstimate: "true",
    allowPartialFill: "false",
  });

  const url = `${baseUrl}?${params.toString()}`;

  return new Promise((resolve, reject) => {
    const options = {
      headers: {
        Authorization: process.env.INCH_API_KEY,
      },
    };

    https
      .get(url, options, (res) => {
        let data = "";

        res.on("data", (chunk) => {
          data += chunk;
        });

        res.on("end", () => {
          try {
            const jsonData = JSON.parse(data);

            if (res.statusCode !== 200) {
              resolve(
                JSON.stringify({ error: `HTTP ${res.statusCode}: ${data}` }),
              );
              return;
            }

            // Extract the data we need for testing
            const result = {
              tx: {
                to: jsonData.tx?.to,
                data: jsonData.tx?.data,
                value: jsonData.tx?.value || "0",
              },
              toAmount: jsonData.toAmount || "0",
            };

            resolve(JSON.stringify(result));
          } catch (error) {
            resolve(JSON.stringify({ error: error.message }));
          }
        });
      })
      .on("error", (error) => {
        resolve(JSON.stringify({ error: error.message }));
      });
  });
}

async function main() {
  if (process.argv.length < 6) {
    console.log(
      JSON.stringify({
        error:
          "Usage: node get_1inch_swap.js <fromToken> <toToken> <amount> <fromAddress>",
      }),
    );
    process.exit(1);
  }

  const [, , fromToken, toToken, amount, fromAddress] = process.argv;

  const result = await get1inchSwapData(
    fromToken,
    toToken,
    amount,
    fromAddress,
  );

  // Write to file for debugging
  const outputPath = path.join(__dirname, "1inch_swap_debug.txt");
  const timestamp = new Date().toISOString();
  const debugOutput = `
=== 1inch Swap Debug Log ===
Timestamp: ${timestamp}
From Token: ${fromToken}
To Token: ${toToken}
Amount: ${amount}
From Address: ${fromAddress}

Result:
${result}

==========================================
`;

  fs.appendFileSync(outputPath, debugOutput);
  // Only output JSON to stdout for FFI to parse
  console.log(result);
}

main();
