"""Measure local Anvil receipts for the slot recycling showcase contracts."""

import argparse
import json
import re
import shutil
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
RAW_STORE = "RawArticleStore"
SHOWCASES = (RAW_STORE, "RecycledArticleStore", "RecycledArticleStoreWithHint")
CREATE = "createArticle(uint56,uint8)"
DELETE = "deleteArticle(uint256)"
STORE = "store(uint256,uint256)"
TX_GAS_LIMIT = 4_000_000
AMSTERDAM_EXECUTION_GAS_CAP = 1 << 24
FUNDED_TX_GAS_LIMIT = 20_000_000
FLOOR_CONTROL_PADDING_BYTES = 2_048
INITIAL_CONTROL_WORD = 257
REWRITE_CONTROL_WORD = 513
LOOPBACK = "127.0.0.1"
RPC_TIMEOUT = 10
RPC_POLL_INTERVAL = 0.05
REFUND_CAP_DIVISOR = 5
TRANSACTION_SUCCEEDED = 1
GAS_PER_ZERO_CALLDATA_BYTE = 4
GAS_PER_NONZERO_CALLDATA_BYTE = 16
EMPTY_SLOT = 0
TOMBSTONE = 1


def artifact(name, source=None):
    path = PROJECT_ROOT / "out" / (source or f"{name}.sol") / f"{name}.json"
    try:
        return json.loads(path.read_text())
    except FileNotFoundError as error:
        raise RuntimeError(f"Missing {path}. Run forge build from the project root.") from error


def calldata(contract, signature, *args):
    return "0x" + contract["methodIdentifiers"][signature] + "".join(f"{arg:064x}" for arg in args)


def wait_for_rpc(process, log):
    listening = re.compile(rf"Listening on {re.escape(LOOPBACK)}:(\d+)")
    deadline = time.monotonic() + RPC_TIMEOUT
    while time.monotonic() < deadline:
        match = listening.search(log.read_text())
        if match:
            return f"http://{LOOPBACK}:{match[1]}"
        if process.poll() is not None:
            raise RuntimeError("Anvil exited before listening. Check that it supports the selected hardfork.")
        time.sleep(RPC_POLL_INTERVAL)
    raise RuntimeError("Timed out waiting for local Anvil")


def rpc_client(url):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def rpc(method, *params):
        payload = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
        request = urllib.request.Request(
            url, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}
        )
        with opener.open(request, timeout=RPC_TIMEOUT) as response:
            result = json.load(response)
        if "error" in result:
            raise RuntimeError(f"{method}: {result['error']}")
        return result["result"]

    return rpc


def transact(rpc, sender, data, contract=None, *, gas_limit=TX_GAS_LIMIT):
    tx = {"from": sender, "data": data, "gas": hex(gas_limit)}
    if contract is not None:
        tx["to"] = contract
    txid = rpc("eth_sendTransaction", tx)
    deadline = time.monotonic() + RPC_TIMEOUT
    while time.monotonic() < deadline:
        receipt = rpc("eth_getTransactionReceipt", txid)
        if receipt is not None:
            if int(receipt["status"], 16) != TRANSACTION_SUCCEEDED:
                raise RuntimeError(f"Transaction {txid} reverted")
            return receipt
        time.sleep(RPC_POLL_INTERVAL)
    raise RuntimeError(f"Timed out waiting for receipt for {txid}")


def validate_storage_pricing(rpc, sender, harness, hardfork, gas_limit):
    if hardfork == "cancun":
        cold_fresh, cold_update = 22_100, 5_000
        intrinsic_base, clear_refund = 21_000, 4_800
        calldata_floor = reservoir = 0
    else:
        cold_storage_access, storage_write = 2_100, 10_000
        state_bytes_per_slot, gas_per_state_byte = 64, 1_530
        sender_base, cold_recipient_access = 12_000, 3_000
        cold_update = cold_storage_access + storage_write
        cold_fresh = cold_update + state_bytes_per_slot * gas_per_state_byte
        intrinsic_base = sender_base + cold_recipient_access
        clear_refund, calldata_floor = 11_616, 64
        reservoir = max(0, gas_limit - AMSTERDAM_EXECUTION_GAS_CAP)

    reservoir_charge_on_creation = min(reservoir, cold_fresh - cold_update)
    fresh_frame_price = cold_fresh - reservoir_charge_on_creation
    rewrite_receipts = {}
    for delete_word in (EMPTY_SLOT, TOMBSTONE):
        address = transact(rpc, sender, harness["bytecode"]["object"])["contractAddress"]
        rewrite_price = cold_fresh if delete_word == EMPTY_SLOT else cold_update
        first_write_padding = FLOOR_CONTROL_PADDING_BYTES if calldata_floor and delete_word == TOMBSTONE else 0
        writes = (
            (INITIAL_CONTROL_WORD, cold_fresh, first_write_padding),
            (delete_word, cold_update, 0),
            (REWRITE_CONTROL_WORD, rewrite_price, 0),
        )
        for word, price, padding in writes:
            data = calldata(harness, STORE, 0, word) + "00" * padding
            receipt = transact(rpc, sender, data, address, gas_limit=gas_limit)
            trace = rpc(
                "debug_traceTransaction",
                receipt["transactionHash"],
                {"disableMemory": True, "disableStack": True, "disableStorage": True},
            )
            steps = trace["structLogs"]
            frame_write_costs = [
                step["gas"] - following["gas"] for step, following in zip(steps, steps[1:])
                if step["op"] == "SSTORE"
            ]
            state_from_reservoir = reservoir_charge_on_creation if price == cold_fresh else 0
            frame_price = price - state_from_reservoir
            if frame_write_costs != [frame_price]:
                raise RuntimeError(f"{hardfork} expected SSTORE frame gas {[frame_price]}, observed {frame_write_costs}")

            data_bytes = bytes.fromhex(data.removeprefix("0x"))
            calldata_gas = sum(
                GAS_PER_NONZERO_CALLDATA_BYTE if byte else GAS_PER_ZERO_CALLDATA_BYTE
                for byte in data_bytes
            )
            frame_spent = steps[0]["gas"] - steps[-1]["gas"] + steps[-1]["gasCost"]
            gross = intrinsic_base + calldata_gas + frame_spent + state_from_reservoir
            refund = min(clear_refund, gross // REFUND_CAP_DIVISOR) if word == EMPTY_SLOT else 0
            floor = intrinsic_base + calldata_floor * len(data_bytes)
            if padding and floor <= gross - refund:
                raise RuntimeError("The padded fresh write must settle at the calldata floor")
            expected = max(gross - refund, floor)
            used = int(receipt["gasUsed"], 16)
            if used != expected:
                raise RuntimeError(f"{hardfork} control expected receipt gas {expected}, observed {used}")
        rewrite_receipts[delete_word] = used

    rewrite_saving = rewrite_receipts[EMPTY_SLOT] - rewrite_receipts[TOMBSTONE]
    print(
        f"{hardfork.capitalize()} control at gas limit {gas_limit:,}. "
        f"Cold fresh SSTORE spent {fresh_frame_price:,} frame gas. "
        f"Overwriting a tombstone saved {rewrite_saving:,} receipt gas on the identical rewrite."
    )


def workloads():
    single = [(CREATE, 100, 1), (DELETE, 0), (CREATE, 200, 2)]
    lifecycle = (
        [(CREATE, i * 100, i) for i in range(1, 11)]
        + [(DELETE, i) for i in range(1, 10, 2)]
        + [(CREATE, i * 100, i % 10) for i in range(11, 16)]
        + [(DELETE, i) for i in range(0, 9, 2)]
        + [(CREATE, i * 100, i % 10) for i in range(16, 21)]
    )
    return {"create/delete/recreate": single, "20 creates and 10 deletes": lifecycle}


def measure_workloads(rpc, sender, showcases, scenarios, gas_limit):
    results = {}
    for name, contract in showcases.items():
        for label, actions in scenarios.items():
            address = transact(rpc, sender, contract["bytecode"]["object"])["contractAddress"]
            receipts = [
                transact(rpc, sender, calldata(contract, *action), address, gas_limit=gas_limit)
                for action in actions
            ]
            blocks = {receipt["blockNumber"] for receipt in receipts}
            if len(blocks) != len(receipts):
                raise RuntimeError("Expected one operation per block")
            results[name, label] = [int(receipt["gasUsed"], 16) for receipt in receipts]
    return results


def benchmark(rpc, hardfork, harness, showcases):
    sender = rpc("eth_accounts")[0]
    scenarios = workloads()
    validate_storage_pricing(rpc, sender, harness, hardfork, TX_GAS_LIMIT)
    results = measure_workloads(rpc, sender, showcases, scenarios, TX_GAS_LIMIT)
    if hardfork == "amsterdam":
        validate_storage_pricing(rpc, sender, harness, hardfork, FUNDED_TX_GAS_LIMIT)
        funded = measure_workloads(rpc, sender, showcases, scenarios, FUNDED_TX_GAS_LIMIT)
        if funded != results:
            raise RuntimeError("Showcase operation receipts differ between the two transaction gas limits")
        print(f"All {sum(map(len, results.values()))} showcase receipts matched across gas limits.")

    for (name, label), gas in results.items():
        total = sum(gas)
        raw_total = sum(results[RAW_STORE, label])
        saving = raw_total - total
        print(f"{name} ({label}): {total:,} net gas {gas}")
        if name != RAW_STORE:
            print(f"  Savings against raw: {saving:,} gas ({saving / raw_total:+.2%})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--anvil", default="anvil", help="Anvil executable or path")
    parser.add_argument("--hardfork", choices=("cancun", "amsterdam"), default="cancun")
    args = parser.parse_args()
    executable = shutil.which(args.anvil)
    if executable is None:
        parser.error(f"Anvil executable {args.anvil!r} does not exist in PATH or is not executable")
    harness = artifact("RecyclerHarness", "SlotRecyclingLib.t.sol")
    showcases = {name: artifact(name) for name in SHOWCASES}

    with tempfile.TemporaryDirectory() as directory:
        log_path = Path(directory) / "anvil.log"
        with log_path.open("w") as log:
            command = [
                str(Path(executable).resolve()), "--host", LOOPBACK, "--port", "0",
                "--steps-tracing", "--hardfork", args.hardfork,
            ]
            with subprocess.Popen(command, cwd=directory, stdout=log, stderr=subprocess.STDOUT) as process:
                try:
                    rpc = rpc_client(wait_for_rpc(process, log_path))
                    print(rpc("web3_clientVersion"))
                    benchmark(rpc, args.hardfork, harness, showcases)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=RPC_TIMEOUT)
                        except subprocess.TimeoutExpired:
                            process.kill()


if __name__ == "__main__":
    main()
