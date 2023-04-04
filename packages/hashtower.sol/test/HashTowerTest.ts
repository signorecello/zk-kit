import { expect } from "chai"
import { Contract } from "ethers"
import { ethers, run } from "hardhat"
import { poseidon } from "circomlibjs"
import ShiftTower from "./utils"

/* eslint-disable jest/valid-expect */
describe("HashTowerTest", () => {
    let contract: Contract

    before(async () => {
        contract = await run("deploy:ht-test", { logs: false })
    })

    it("Should produce correct count, digests and digest of digests", async () => {
        const hashTowerId = ethers.utils.formatBytes32String("test1")

        const N = 150
        for (let i = 0; i < N; i += 1) {
            const tx = contract.add(hashTowerId, i)
            await tx
        }
        const [count, digests, digestOfDigests] = await contract.getDataForProving(hashTowerId)

        expect(count).to.equal(N)

        expect(digests[0]).to.equal(
            BigInt("7484852499570635450337779587061833141700590058395918107227385307780465498841")
        )
        expect(digests[1]).to.equal(
            BigInt("18801712394745483811033456933953954791894699812924877968490149877093764724813")
        )
        expect(digests[2]).to.equal(
            BigInt("18495397265763935736123111771752209927150052777598404957994272011704245682779")
        )
        expect(digests[3]).to.equal(
            BigInt("11606235313340788975553986881206148975708550071371494991713397040288897077102")
        )
        for (let i = 4; i < digests.length; i += 1) {
            expect(digests[i]).to.equal(BigInt("0"))
        }

        expect(digestOfDigests).to.equal(
            BigInt("19260615748091768530426964318883829655407684674262674118201416393073357631548")
        )
    })

    it("Should have the same output as the Javascript fixture)", async () => {
        const hashTowerId = ethers.utils.formatBytes32String("test2")

        const H2 = (a: number, b: number) => poseidon([a, b])
        const W = 4
        const shiftTower = ShiftTower(W, (vs) => vs.reduce(H2))
        for (let i = 0; i < 150; i += 1) {
            const maxLevel = shiftTower.add(i)

            const tx = contract.add(hashTowerId, i)
            await tx

            // event
            for (let lv = 0; lv <= maxLevel; lv += 1) {
                const fullLevelIndex = shiftTower.S[lv].length + shiftTower.L[lv].length - 1
                const value = shiftTower.L[lv].at(-1)
                await expect(tx).to.emit(contract, "Add").withArgs(lv, fullLevelIndex, value)
            }

            // count and digest
            const [count, digests, digestOfDigests] = await contract.getDataForProving(hashTowerId)

            expect(count).to.equal(i + 1)

            const D = shiftTower.L.map((l) => l.reduce(H2))
            for (let lv = 0; lv < digests.length; lv += 1) {
                expect(digests[lv]).to.equal(D[lv] ?? 0)
            }

            expect(digestOfDigests).to.equal(D.reverse().reduce(H2))
        }
    })
})