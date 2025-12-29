const fs = require("fs")

// Loads environment variables from .env file (if it exists)
require("dotenv").config()
const { Location, ReturnType, CodeLanguage } = require("@chainlink/functions-toolkit")

const reserveAddress = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2".toLowerCase()
// Configure the request by setting the fields below
const requestConfig = {
  // Location of source code (only Inline is currently supported)
  codeLocation: Location.Inline,
  // Code language (only JavaScript is currently supported)
  codeLanguage: CodeLanguage.JavaScript,
  // String containing the source code to be executed
  // location of secrets (Inline or Remote)
  secretsLocation: Location.DONHosted,
  source: fs.readFileSync("./query-SxT-update-rates.js").toString(),
  perNodeSecrets: [],

  walletPrivateKey: process.env["PRIVATE_KEY"],
  secrets: { apiKey: process.env.API_KEY ?? "" },
  // AAVE_V3_ETHEREUM.POOL_EVT_RESERVEDATAUPDATED
  // `SELECT   BLOCK_NUMBER,   CONTRACT_ADDRESS,   DECODE_ERROR,   EVENT_INDEX,   LIQUIDITYINDEX,   LIQUIDITYRATE / 1e27 AS LIQUIDITYRATE,   RESERVE,   STABLEBORROWRATE / 1e27 AS STABLEBORROWRATE,   TIME_STAMP,   TRANSACTION_HASH,   VARIABLEBORROWINDEX,   VARIABLEBORROWRATE / 1e27 AS VARIABLEBORROWRATE FROM   LENDVEST_TEST.POOL_EVT_RESERVEDATAUPDATED_TP10 WHERE   RESERVE = '${reserveAddress}' ORDER BY   TIME_STAMP DESC LIMIT   1;`
  args: [
    `SELECT   BLOCK_NUMBER,   CONTRACT_ADDRESS,   DECODE_ERROR,   EVENT_INDEX,   LIQUIDITYINDEX,   LIQUIDITYRATE / 1e27 AS LIQUIDITYRATE,   RESERVE,   STABLEBORROWRATE / 1e27 AS STABLEBORROWRATE,   TIME_STAMP,   TRANSACTION_HASH,   VARIABLEBORROWINDEX,   VARIABLEBORROWRATE / 1e27 AS VARIABLEBORROWRATE FROM   AAVE_V3_ETHEREUM.POOL_EVT_RESERVEDATAUPDATED WHERE   RESERVE = '${reserveAddress}' ORDER BY   TIME_STAMP DESC LIMIT   1;`, process.env.API_URL,process.env.TOKEN],

  expectedReturnType: ReturnType.bytes,
  // Redundant URLs which point to encrypted off-chain secrets
  secretsURLs: [],
  // Default offchain secrets object used by the `functions-build-offchain-secrets` command
  globalOffchainSecrets: {},
}

module.exports = requestConfig
