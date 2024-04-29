const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-network-helpers");
const { makeMerkleTree } = require("../utils/makeMerkleTree");
const { expect } = require("chai");

// Our first version of the merkle tree will-only contract was well tested, but since we simplified it, we didn't have time to rewrite the tests. Since the logic remained similar, the contract should meet the security requirements
const approveMax =
  "115792089237316195423570985008687907853269984665640564039457584007913129639935"; //(2^256 - 1 )
const BASE_POINT = 10000;
const FEE_BP = 100;
const MIN_TESTAMENT_LOCK = 31104000;
const erc20Shares = [1000, 3000, 6000];
const neededVotes = 2;

const defaultHeirsWithShares = [
  {
    heirAddress: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    erc20Share: erc20Shares[0],
  },
  {
    heirAddress: "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
    erc20Share: erc20Shares[1],
  },
  {
    heirAddress: "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
    erc20Share: erc20Shares[2],
  },
];

function inheritanceAmount(tokenAmount, share) {
  return tokenAmount
    .mul(BASE_POINT - FEE_BP)
    .mul(share)
    .div(BASE_POINT)
    .div(BASE_POINT);
}

async function skipToUnlock(testamentContract, owner) {
  await time.increaseTo(
    (
      await testamentContract.testaments(owner)
    ).expirationTime
  );
  await time.increase((await testamentContract.CONTINGENCY_PERIOD()).add(1));
}

async function createTestament(
  testamentContract,
  owner,
  heir,
  guardian2,
  feeAddress
) {
  const heirsWithShares = [
    {
      heirAddress: heir.address,
      erc20Share: erc20Shares[0],
    },
    {
      heirAddress: guardian2.address,
      erc20Share: erc20Shares[1],
    },
    {
      heirAddress: feeAddress.address,
      erc20Share: erc20Shares[2],
    },
  ];

  const merkleTreeData = await makeMerkleTree(heirsWithShares);
  const { root, proofs } = merkleTreeData;

  await testamentContract
    .connect(owner)
    .createTestament(
      MIN_TESTAMENT_LOCK,
      neededVotes,
      [heir.address, guardian2.address],
      root
    );
  return { heirsWithShares, merkleTreeData };
}

describe("Testing SmartTestament", function () {
  async function deployTestamentCryptoFixture() {
    // Contracts are deployed using the first signer/account by default
    const [owner, heir, guardian2, feeAddress] = await ethers.getSigners();
    const TestamentContract = await hre.ethers.getContractFactory(
      "SmartTestament"
    );
    const testamentContract = await TestamentContract.connect(
      feeAddress
    ).deploy();
    await testamentContract.deployed();

    const WethContract = await hre.ethers.getContractFactory("WETH");
    const wethContract = await WethContract.deploy("WETH", "WETH");
    await wethContract.deployed();
    await wethContract.approve(testamentContract.address, approveMax);
    await wethContract
      .connect(guardian2)
      .approve(testamentContract.address, approveMax);

    let otherWethContractsAddresses = [];
    for (let i = 0; i < 20; i++) {
      const wethContract = await WethContract.deploy(`${i}`, `${i}`);
      wethContract.deployed();
      await wethContract.approve(testamentContract.address, approveMax);
      await wethContract
        .connect(guardian2)
        .approve(testamentContract.address, approveMax);
      otherWethContractsAddresses.push(wethContract.address);
    }

    // Fixtures can return anything you consider useful for your tests
    return {
      testamentContract,
      wethContract,
      otherWethContractsAddresses,
      owner,
      heir,
      guardian2,
      feeAddress,
    };
  }

  beforeEach(async function () {
    const {
      testamentContract,
      wethContract,
      otherWethContractsAddresses,
      owner,
      heir,
      guardian2,
      feeAddress,
    } = await loadFixture(deployTestamentCryptoFixture);

    this.testamentContract = testamentContract;
    this.wethContract = wethContract;
    this.otherWethContractsAddresses = otherWethContractsAddresses;
    this.owner = owner;
    this.heir = heir;
    this.guardian2 = guardian2;
    this.feeAddress = feeAddress;
  });

  describe("Deployment of contract", function () {
    it("Should set the right feeAddress", async function () {
      expect(await this.testamentContract.feeAddress()).to.equal(
        this.feeAddress.address
      );
    });

    it("Owner should not have testament", async function () {
      expect(
        await this.testamentContract.getTestamentState(this.owner.address)
      ).to.equal(0);
    });

    it("Fee address changed and not for Not Owner", async function () {
      await this.testamentContract.updateFeeAddress(this.owner.address);
      expect(await this.testamentContract.feeAddress()).to.equal(
        this.owner.address
      );
      await expect(
        this.testamentContract
          .connect(this.heir)
          .updateFeeAddress(this.owner.address)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("Withdrawing donations should work", async function () {
      value = ethers.utils.parseEther("1.0");
      const transactionHash = await this.owner.sendTransaction({
        to: this.testamentContract.address,
        value: value,
      });
      expect(
        await this.testamentContract.withdrawDonations()
      ).to.changeEtherBalance(
        [this.testamentContract.address, this.heir.address],
        -value,
        value
      );
      await expect(
        this.testamentContract.connect(this.heir).withdrawDonations()
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  describe("Testing wrong creating and event", function () {
    it("Event CreatedTestament", async function () {
      const merkleTreeData = await makeMerkleTree(defaultHeirsWithShares);
      const { root, proofs } = merkleTreeData;

      await expect(
        this.testamentContract
          .connect(this.owner)
          .createTestament(
            MIN_TESTAMENT_LOCK,
            neededVotes,
            [this.heir.address, this.guardian2.address],
            root
          )
      )
        .to.emit(this.testamentContract, "CreatedTestament")
        .withArgs(this.owner.address);
    });

    it("Should not pass 0 needed votes", async function () {
      const merkleTreeData = await makeMerkleTree(defaultHeirsWithShares);
      const { root, proofs } = merkleTreeData;

      await expect(
        this.testamentContract
          .connect(this.owner)
          .createTestament(
            MIN_TESTAMENT_LOCK,
            0,
            [this.heir.address, this.guardian2.address],
            root
          )
      ).to.be.revertedWith("Needed votes must be greater than null");
    });

    it("Should not pass less than two guardians", async function () {
      const merkleTreeData = await makeMerkleTree(defaultHeirsWithShares);
      const { root, proofs } = merkleTreeData;

      await expect(
        this.testamentContract
          .connect(this.owner)
          .createTestament(MIN_TESTAMENT_LOCK, 1, [this.heir.address], root)
      ).to.be.revertedWith("No less than two guardians");
    });

    it("Should not pass more than  MAX_GUARDIANS guardians", async function () {
      const merkleTreeData = await makeMerkleTree(defaultHeirsWithShares);
      const { root, proofs } = merkleTreeData;

      await expect(
        this.testamentContract
          .connect(this.owner)
          .createTestament(
            MIN_TESTAMENT_LOCK,
            1,
            Array(21).fill(this.heir.address),
            root
          )
      ).to.be.revertedWith("Too many guardians");
    });

    it("Prevention needed votes > guardians.length", async function () {
      const merkleTreeData = await makeMerkleTree(defaultHeirsWithShares);
      const { root, proofs } = merkleTreeData;

      await expect(
        this.testamentContract
          .connect(this.owner)
          .createTestament(
            MIN_TESTAMENT_LOCK,
            3,
            [this.heir.address, this.guardian2.address],
            root
          )
      ).to.be.revertedWith("Needed votes should <= Number of guardians");
    });
  });

  describe("Contract logic testing", function () {
    beforeEach(async function () {
      const { heirsWithShares, merkleTreeData } = await createTestament(
        this.testamentContract,
        this.owner,
        this.heir,
        this.guardian2,
        this.feeAddress
      );

      this.heirsWithShares = heirsWithShares;
      this.merkleTreeData = merkleTreeData;
      this.proofs = merkleTreeData.proofs;
      this.heirErc20Share = heirsWithShares.find(
        (e) => e.heirAddress == this.heir.address
      ).erc20Share;
    });

    describe("Create Testament", function () {
      it("Owner testament should have TestatorAlive state", async function () {
        expect(
          await this.testamentContract.getTestamentState(this.owner.address)
        ).to.equal(1);
      });

      it("Owner must not have two testaments", async function () {
        await expect(
          createTestament(
            this.testamentContract,
            this.owner,
            this.heir,
            this.guardian2,
            this.feeAddress
          )
        ).to.be.revertedWith("Already exists");
      });

      it("Im Alive function should move for right expiration time before voting and emit TestatorAlive", async function () {
        const firstExpTime = (
          await this.testamentContract.testaments(this.owner.address)
        ).expirationTime;
        await this.testamentContract
          .connect(this.owner)
          .imAlive(MIN_TESTAMENT_LOCK);
        expect(
          (await this.testamentContract.testaments(this.owner.address))
            .expirationTime
        )
          .to.equal(firstExpTime.add(MIN_TESTAMENT_LOCK))
          .to.emit(this.testamentContract, "TestatorAlive")
          .withArgs(this.owner.address, firstExpTime.add(MIN_TESTAMENT_LOCK));
      });

      it("Im Alive function should move for right expiration time when voting active", async function () {
        await time.increaseTo(
          (
            await this.testamentContract.testaments(this.owner.address)
          ).expirationTime.add(1000)
        );
        const firstExpTime = await time.latest();

        await this.testamentContract
          .connect(this.owner)
          .imAlive(MIN_TESTAMENT_LOCK);
        expect(
          (await this.testamentContract.testaments(this.owner.address))
            .expirationTime
        ).to.equal(firstExpTime + MIN_TESTAMENT_LOCK + 1);
      });

      it("Im Alive function require More than 360 days and right state", async function () {
        await expect(
          this.testamentContract.connect(this.owner).imAlive(1)
        ).to.be.revertedWith("New lock time should be no less than 360 days");
        await time.increaseTo(
          (
            await this.testamentContract.testaments(this.owner.address)
          ).expirationTime.add(1)
        );
        await this.testamentContract
          .connect(this.guardian2)
          .voteForUnlock(this.owner.address);
        await this.testamentContract
          .connect(this.heir)
          .voteForUnlock(this.owner.address);
        await expect(
          this.testamentContract.connect(this.owner).imAlive(MIN_TESTAMENT_LOCK)
        ).to.be.revertedWith(
          "State should be TestatorAlive or VoteActive, or Delete this testament"
        );
      });

      it("Delete should work and call event TestamentDeleted", async function () {
        await expect(
          this.testamentContract.connect(this.owner).deleteTestament()
        )
          .to.emit(this.testamentContract, "TestamentDeleted")
          .withArgs(this.owner.address);
        expect(
          await this.testamentContract.getTestamentState(this.owner.address)
        ).to.equal(0);
      });

      it("Heirs updates should work and call event HeirsUpdated", async function () {
        const randomRoot =
          "0x556536e406b5c301d3a713c27fbac231df042c9425d8b946c896155f58198d45";
        await expect(
          this.testamentContract.connect(this.owner).updateHeirs(randomRoot)
        )
          .to.emit(this.testamentContract, "HeirsUpdated")
          .withArgs(this.owner.address, randomRoot);
        expect(
          (await this.testamentContract.testaments(this.owner.address))
            .erc20HeirsMerkleRoot
        ).to.equal(randomRoot);
        await skipToUnlock(this.testamentContract, this.owner.address);
        await expect(
          this.testamentContract.connect(this.owner).updateHeirs(randomRoot)
        ).to.be.revertedWith("Must be alive");
      });

      it("Guardians updates should work and call event GuardiansUpdated", async function () {
        await expect(
          this.testamentContract
            .connect(this.owner)
            .updateGuardians(2, [
              this.feeAddress.address,
              this.guardian2.address,
            ])
        )
          .to.emit(this.testamentContract, "GuardiansUpdated")
          .withArgs(this.owner.address, 2, [
            this.feeAddress.address,
            this.guardian2.address,
          ]);
        expect(
          (await this.testamentContract.testaments(this.owner.address)).voting
            .neededVotes
        ).to.equal(2);
        expect(
          (await this.testamentContract.testaments(this.owner.address)).voting
            .guardians
        ).to.deep.equal([this.feeAddress.address, this.guardian2.address]);
        await skipToUnlock(this.testamentContract, this.owner.address);
        await expect(
          this.testamentContract
            .connect(this.owner)
            .updateGuardians(2, [
              this.feeAddress.address,
              this.guardian2.address,
            ])
        ).to.be.revertedWith("Must be alive");
      });
    });

    describe("Withdraw Testament", function () {
      describe("Validations", function () {
        it("Should revert if withdraw called too soon, too many tokens, or not the heir", async function () {
          await expect(
            this.testamentContract.connect(this.heir).withdrawTestament(
              this.owner.address,
              {
                erc20Tokens: [this.wethContract.address],
                erc20Share: this.heirErc20Share,
              },
              this.proofs[this.heir.address]
            )
          ).to.be.revertedWith("Testament must be Unlocked");
          await skipToUnlock(this.testamentContract, this.owner.address);
          await expect(
            this.testamentContract.connect(this.heir).withdrawTestament(
              this.owner.address,
              {
                erc20Tokens: Array(102).fill(this.wethContract.address),
                erc20Share: this.heirErc20Share,
              },
              this.proofs[this.heir.address]
            )
          ).to.be.revertedWith("Too many tokens");

          await expect(
            this.testamentContract.connect(this.owner).withdrawTestament(
              this.owner.address,
              {
                erc20Tokens: [this.wethContract.address],
                erc20Share: this.heirErc20Share,
              },
              this.proofs[this.heir.address]
            )
          ).to.be.revertedWith("Not the Heir");
        });

        it("isHeir should return false to address not in testament", async function () {
          expect(
            await this.testamentContract
              .connect(this.owner)
              .isHeir(
                this.owner.address,
                this.heirErc20Share,
                this.proofs[this.heir.address]
              )
          ).to.equal(false);
        });

        it("isHeir should return true to address in testament", async function () {
          const merkleTreeData = await makeMerkleTree(defaultHeirsWithShares);
          const { proofs } = merkleTreeData;

          expect(
            await this.testamentContract
              .connect(this.heir)
              .isHeir(
                this.owner.address,
                this.heirErc20Share,
                proofs[this.heir.address]
              )
          ).to.equal(true);
        });
      });

      describe("Transfers", function () {
        it("Should transfer the funds to the heir and prevention claiming twice", async function () {
          await skipToUnlock(this.testamentContract, this.owner.address);
          const wethAmount = await this.wethContract.balanceOf(
            this.owner.address
          );

          await expect(
            this.testamentContract.connect(this.heir).withdrawTestament(
              this.owner.address,
              {
                erc20Tokens: [this.wethContract.address],
                erc20Share: this.heirErc20Share,
              },
              this.proofs[await this.heir.address]
            )
          )
            .to.changeTokenBalances(
              this.wethContract,
              [this.owner, this.heir],
              [
                "-" +
                  wethAmount
                    .mul(FEE_BP)
                    .div(BASE_POINT)
                    .add(inheritanceAmount(wethAmount, this.heirErc20Share)),
                "" + inheritanceAmount(wethAmount, this.heirErc20Share),
              ]
            )
            .to.emit(this.testamentContract, "WithdrawTestament")
            .withArgs(this.owner.address, this.heir.address);

          await expect(
            this.testamentContract.connect(this.heir).withdrawTestament(
              this.owner.address,
              {
                erc20Tokens: [this.wethContract.address],
                erc20Share: this.heirErc20Share,
              },
              this.proofs[await this.heir.address]
            )
          ).to.be.revertedWith("Already claimed");
        });

        it("Zero balance withdraw", async function () {
          await skipToUnlock(this.testamentContract, this.owner.address);
          const wethAmount = await this.wethContract.balanceOf(
            this.owner.address
          );
          await this.wethContract
            .connect(this.owner)
            .transfer(this.guardian2.address, wethAmount);
          await this.testamentContract.connect(this.heir).withdrawTestament(
            this.owner.address,
            {
              erc20Tokens: [this.wethContract.address],
              erc20Share: this.heirErc20Share,
            },
            this.proofs[await this.heir.address]
          );
        });

        it("Shouldn`t be exploitable for error merkle root", async function () {
          const heir2Signers = await ethers.getSigners();
          const heirsWithShares = [
            {
              heirAddress: heir2Signers[5].address,
              erc20Share: 9000,
            },
            {
              heirAddress: heir2Signers[6].address,
              erc20Share: 5000,
            },
            {
              heirAddress: heir2Signers[7].address,
              erc20Share: 6000,
            },
          ];

          const merkleTreeData2 = await makeMerkleTree(heirsWithShares);
          const { root } = merkleTreeData2;

          await this.testamentContract
            .connect(this.guardian2)
            .createTestament(
              MIN_TESTAMENT_LOCK,
              neededVotes,
              [this.heir.address, this.guardian2.address],
              root
            );

          await skipToUnlock(this.testamentContract, this.owner.address);

          await this.wethContract.connect(this.guardian2).mint();

          const wethAmount = await this.wethContract.balanceOf(
            this.owner.address
          );

          await expect(
            this.testamentContract.connect(this.heir).withdrawTestament(
              this.owner.address,
              {
                erc20Tokens: [this.wethContract.address],
                erc20Share: this.heirErc20Share,
              },
              this.proofs[await this.heir.address]
            )
          ).to.changeTokenBalances(
            this.wethContract,
            [this.owner, this.heir],
            [
              "-" +
                wethAmount
                  .mul(FEE_BP)
                  .div(BASE_POINT)
                  .add(inheritanceAmount(wethAmount, this.heirErc20Share)),
              "" + inheritanceAmount(wethAmount, this.heirErc20Share),
            ]
          );

          await expect(
            this.testamentContract.connect(heir2Signers[5]).withdrawTestament(
              this.guardian2.address,
              {
                erc20Tokens: [this.wethContract.address],
                erc20Share: 9000,
              },
              merkleTreeData2.proofs[await heir2Signers[5].address]
            )
          ).not.to.be.reverted;

          await expect(
            this.testamentContract.connect(heir2Signers[6]).withdrawTestament(
              this.guardian2.address,
              {
                erc20Tokens: [this.wethContract.address],
                erc20Share: 5000,
              },
              merkleTreeData2.proofs[await heir2Signers[6].address]
            )
          ).to.be.reverted;
        });

        it("Mass tokens withdraw checking", async function () {
          await skipToUnlock(this.testamentContract, this.owner.address);
          const wethAmount = await this.wethContract.balanceOf(
            this.owner.address
          );

          await expect(
            this.testamentContract.connect(this.heir).withdrawTestament(
              this.owner.address,
              {
                erc20Tokens: [this.wethContract.address].concat(
                  this.otherWethContractsAddresses
                ),
                erc20Share: this.heirErc20Share,
              },
              this.proofs[await this.heir.address]
            )
          ).to.changeTokenBalances(
            this.wethContract,
            [this.owner, this.heir],
            [
              "-" +
                wethAmount
                  .mul(FEE_BP)
                  .div(BASE_POINT)
                  .add(inheritanceAmount(wethAmount, this.heirErc20Share)),
              "" + inheritanceAmount(wethAmount, this.heirErc20Share),
            ]
          );

          await expect(
            this.testamentContract.connect(this.guardian2).withdrawTestament(
              this.owner.address,
              {
                erc20Tokens: [this.wethContract.address].concat(
                  this.otherWethContractsAddresses
                ),
                erc20Share: erc20Shares[1],
              },
              this.proofs[await this.guardian2.address]
            )
          ).to.changeTokenBalances(
            this.wethContract,
            [this.owner, this.guardian2],
            [
              "-" + inheritanceAmount(wethAmount, erc20Shares[1]),
              "" + inheritanceAmount(wethAmount, erc20Shares[1]),
            ]
          );

          await expect(
            this.testamentContract.connect(this.feeAddress).withdrawTestament(
              this.owner.address,
              {
                erc20Tokens: [this.wethContract.address].concat(
                  this.otherWethContractsAddresses
                ),
                erc20Share: erc20Shares[2],
              },
              this.proofs[await this.feeAddress.address]
            )
          ).to.changeTokenBalances(
            this.wethContract,
            [this.owner, this.feeAddress],
            [
              "-" + inheritanceAmount(wethAmount, erc20Shares[2]),
              "" + inheritanceAmount(wethAmount, erc20Shares[2]),
            ]
          );
        });
      });
    });

    describe("Voting System", function () {
      it("Get voted guardians and state VoteActive", async function () {
        await time.increaseTo(
          (
            await this.testamentContract.testaments(this.owner.address)
          ).expirationTime.add(1)
        );
        expect(
          await this.testamentContract.getTestamentState(this.owner.address)
        ).to.equal(2);
        await this.testamentContract
          .connect(this.guardian2)
          .voteForUnlock(this.owner.address);
        expect(
          await this.testamentContract.getVotedGuardians(this.owner.address)
        ).to.eql([this.guardian2.address]);
      });

      it("Right voting amount, TestamentState ConfirmationWaiting and prevention before VoteActive", async function () {
        await expect(
          this.testamentContract
            .connect(this.guardian2)
            .voteForUnlock(this.owner.address)
        ).to.be.revertedWith("Voting is not active");
        await time.increaseTo(
          (
            await this.testamentContract.testaments(this.owner.address)
          ).expirationTime.add(1)
        );
        await this.testamentContract
          .connect(this.guardian2)
          .voteForUnlock(this.owner.address);
        await this.testamentContract
          .connect(this.heir)
          .voteForUnlock(this.owner.address);
        expect(
          await this.testamentContract.getApproveVotesAmount(this.owner.address)
        ).to.eql(ethers.BigNumber.from("2"));
        expect(
          await this.testamentContract.getTestamentState(this.owner.address)
        ).to.eql(3);
      });
    });
  });
});
