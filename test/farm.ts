import { assert, expect } from "chai";
import { ethers } from "ethers";
import { starknet } from "hardhat";
import { Account, StarknetContract } from "hardhat/types/runtime";
import {
  deployToken,
  deployFarm,
  TIMEOUT,
  approve,
  getEventData,
  uintToBigInt,
  BURN_ADDRESS,
  addressToFelt,
  tokenDecimals,
  // eslint-disable-next-line node/no-missing-import
} from "./utils";


describe("Stark Defi Farm", function () {
  this.timeout(TIMEOUT); // 15 mins

  let user1Account: Account;
  let randomAccount: Account;
  let devAccount: Account;
  let starkDefiToken: StarknetContract;
  let lptoken0Contract: StarknetContract;
  let lptoken1Contract: StarknetContract;
  let farmContract: StarknetContract;

  before(async () => {
    const preDeployedAccounts = await starknet.devnet.getPredeployedAccounts();

    console.log("Started deployment");

    user1Account = await starknet.getAccountFromAddress(
      preDeployedAccounts[0].address,
      preDeployedAccounts[0].private_key,
      "OpenZeppelin"
    );
    console.log("User 1 Account", user1Account.address);

    randomAccount = await starknet.getAccountFromAddress(
      preDeployedAccounts[1].address,
      preDeployedAccounts[1].private_key,
      "OpenZeppelin"
    );
    console.log("Random Account", randomAccount.address);

    devAccount = await starknet.getAccountFromAddress(
      preDeployedAccounts[2].address,
      preDeployedAccounts[2].private_key,
      "OpenZeppelin"
    );
    console.log("Dev Account", devAccount.address);

    starkDefiToken = await deployToken(devAccount, "Stark Defi Token", "STARKD");
    lptoken0Contract = await deployToken(randomAccount, "Liquidity Token 0", "LPT0");
    lptoken1Contract = await deployToken(randomAccount, "Liquidity Token 1", "LPT1");
    farmContract = await deployFarm(devAccount.address, starkDefiToken.address, 2);

  });

  // it("Should create a farm", async () => {
    
  // });

});
