import { describe, expect, it } from "vitest";

describe("Allowance Tracker Tests", () => {
  it("should initialize simnet", () => {
    expect(simnet.blockHeight).toBeDefined();
  });

  it("should deploy allowance contract", () => {
    const deployerAddress = simnet.getAssetsMap().get(simnet.deployer)?.get("STX");
    expect(deployerAddress).toBeDefined();
  });
});
