# Fork Testing with Saved Swap Data

This directory contains swap data for running fork tests without a 1inch API key.

# Generating New Data

To generate new data put 1inch API key inside the .env file and run `node test/scripts/calculate_and_save_swap_data.js` and it will save swap data for the current block for test and put the block number in the file name.
Note: these are specific values, thus, changing the contract or the tests will most likely invalidate old swap data.
