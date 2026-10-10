#!/usr/bin/env python3
"""Run actual transactions using the exact plain eth_estimateGas result on a disposable Anvil.
No keys, environment variables, external Python packages, or live broadcasts. Optional read-only fork.
Usage: python3 script/check_estimated_gas.py [--fork-url https://rpc.flashbots.net]
Run forge build first. Results are printed as JSON; no repository filesystem permissions are needed by EVM code.
"""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
CAP = 16_700_000
MANAGER = "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543"
IMD = "0x2B69099E59b05901faA1DD164fabf098bf831E82"
STACKER = "0x293C7134Ab8f6Bf1D8fF44Ed806575f8F1bAF477"
INTAKE = "0x1397434cd35e8a9C8aC312A61D3A285EB31dea56"
ASSET = "0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A"
START = 1791775740

def word(value):
    return f"{int(value,16) if isinstance(value,str) else value:064x}"

def dynamic(value):
    raw = value.removeprefix("0x")
    return word(len(raw)//2) + raw + "0"*((-len(raw))%64)

def cast(*args):
    return subprocess.check_output(["cast", *map(str,args)], text=True).strip()

def call_data(signature,*args):
    return cast("calldata",signature,*args)

def artifact(name):
    paths=list((ROOT/"out").glob(f"*/{name}.json"))
    assert len(paths)==1,(name,paths)
    return json.loads(paths[0].read_text())

def bytecode(name):
    return artifact(name)["bytecode"]["object"]

def array_bytes(values):
    encoded = [dynamic(v) for v in values]
    offset = 32*len(values)
    offsets = []
    for value in encoded:
        offsets.append(word(offset))
        offset += len(value)//2
    return word(32)+word(len(values))+"".join(offsets+encoded)

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--fork-url")
    args=parser.parse_args()
    with socket.socket() as sock:
        sock.bind(("127.0.0.1",0));port=sock.getsockname()[1]
    command=["anvil","--port",str(port),"--chain-id","11155111","--hardfork","osaka","--gas-limit","30000000","--silent"]
    if args.fork_url:
        command += ["--fork-url",args.fork_url]
    process=subprocess.Popen(command,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    url=f"http://127.0.0.1:{port}"
    records=[]
    def rpc(method,params=None):
        req=urllib.request.Request(url,data=json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params or []}).encode(),headers={"Content-Type":"application/json"})
        with urllib.request.urlopen(req,timeout=60) as response:
            result=json.load(response)
        if "error" in result: raise RuntimeError(f"{method}: {result['error']}")
        return result["result"]
    try:
        for _ in range(200):
            try:
                accounts=rpc("eth_accounts");break
            except (OSError,RuntimeError):
                if process.poll() is not None: raise RuntimeError(process.stderr.read().decode())
                time.sleep(0.1)
        else: raise RuntimeError("Anvil failed to start within 20 seconds")
        fork_block=rpc("eth_getBlockByNumber",["latest",False])
        owner,trader,keeper=accounts[:3]
        def tx(label,to=None,data="0x",sender=owner):
            value={"from":sender,"data":data}
            if to: value["to"]=to
            estimate=rpc("eth_estimateGas",[value])
            value["gas"]=estimate
            transaction=rpc("eth_sendTransaction",[value])
            receipt=None
            for _ in range(100):
                receipt=rpc("eth_getTransactionReceipt",[transaction])
                if receipt: break
                time.sleep(0.01)
            if not receipt or receipt["status"]!="0x1":
                print(json.dumps({"failedAction":label,"estimate":estimate,"receipt":receipt,"previous":records,
                    "trace":rpc("debug_traceTransaction",[transaction,{"tracer":"callTracer"}])},indent=2),flush=True)
                raise AssertionError((label,estimate,receipt))
            used=int(receipt["gasUsed"],16)
            assert used <= CAP,(label,used)
            records.append({"action":label,"estimated":int(estimate,16),"used":used})
            return receipt
        def deploy(name,args=""):
            return tx("fixture "+name,data=bytecode(name)+args)["contractAddress"]
        def read(to,signature,*args):
            return rpc("eth_call",[{"to":to,"data":call_data(signature,*args)},"latest"])
        # All four application constructors in one transaction, with no dependency code installed yet.
        factory=deploy("DeploymentFactory")
        predicted=[]
        for nonce in range(1,5):
            digest=cast("keccak","0xd694"+factory[2:]+f"{nonce:02x}")
            predicted.append("0x"+digest[-40:])
        token,gate,distributor,launch=predicted
        codes=[bytecode("PLEA")+word(owner),bytecode("CabalGate")+word(token),
            bytecode("PleaDistributor")+word(token)+word(owner),
            bytecode("PleaLaunch")+word(token)+word(gate)+word(distributor)+word(START)]
        tx("atomic four-contract launch",factory,cast("sig","deploy(bytes[])")+array_bytes(codes))
        for address in predicted: assert rpc("eth_getCode",[address,"latest"])!="0x"
        # Install constructor-built v4 core and deterministic external-service fixtures at fixed addresses.
        pm=deploy("PoolManager",word(owner))
        runtime=rpc("eth_getCode",[pm,"latest"]).lower().replace(word(pm),word(MANAGER))
        rpc("anvil_setCode",[MANAGER,runtime])
        asset=deploy("TestAsset")
        runtime=rpc("eth_getCode",[asset,"latest"])
        rpc("anvil_setCode",[IMD,runtime]);rpc("anvil_setCode",[ASSET,runtime])
        simd=deploy("TestSIMD",word(IMD))
        stacker=deploy("Stacker",word(IMD)+word(simd))
        rpc("anvil_setCode",[STACKER,rpc("eth_getCode",[stacker,"latest"])])
        rpc("anvil_impersonateAccount",[STACKER]);rpc("anvil_setBalance",[STACKER,hex(10**20)])
        tx("fixture stacker vault approval",IMD,call_data("approve(address,uint256)",simd,2**256-1),STACKER)
        rpc("anvil_stopImpersonatingAccount",[STACKER])
        intake=deploy("MockIntake")
        rpc("anvil_setCode",[INTAKE,rpc("eth_getCode",[intake,"latest"])])
        initcode=bytecode("PleaHook")+word(token)+word(gate)+word(owner)
        init_hash=read(launch,"hookInitcodeHash()")
        # Pure off-chain salt search performed by eth_call to the delivered Solidity script.
        miner=deploy("MineSalt")
        for start in range(0,1_000_000,10_000):
            result=read(miner,"run(address,bytes32,uint256,uint256)",launch,init_hash,start,10_000)
            words=[result[2+i:2+i+64] for i in range(0,len(result)-2,64)]
            if int(words[0],16)==1: break
        else: raise RuntimeError("No salt in bounded search; increase the search range")
        salt="0x"+words[1];hook="0x"+words[2][-40:]
        data=cast("sig","deployHook(bytes32,bytes)")+salt[2:]+word(64)+dynamic(initcode)
        tx("deployHook",launch,data)
        tx("seed",launch,call_data("seed()"))
        tx("allow",token,call_data("allow(address)",keeper))
        tx("fixture IMD mint",IMD,call_data("mint(address,uint256)",trader,100000*10**18))
        tx("fixture oracle asset mint",ASSET,call_data("mint(address,uint256)",trader,10*10**18))
        tx("approve IMD",IMD,call_data("approve(address,uint256)",gate,2**256-1),trader)
        tx("approve oracle asset",ASSET,call_data("approve(address,uint256)",gate,2**256-1),trader)
        tx("approve PLEA",token,call_data("approve(address,uint256)",gate,2**256-1),trader)
        seed_at=int(read(hook,"seededAt()"),16)
        rpc("evm_setNextBlockTimestamp",[seed_at+5401]);rpc("evm_mine")
        plea0=bool(int(read(hook,"plea0()"),16))
        limit=1461446703485210103287273052203988822378723970341 if plea0 else 4295128740
        tx("buy first credit",gate,call_data("buy(uint256,uint256,uint160)",10*10**18,1,limit),trader)
        assert int(read(simd,"balanceOf(address)",trader),16)>0
        assert int(read(STACKER,"stackedBy(address,address)",hook,trader),16)>0
        assert int(read(MANAGER,"balanceOf(address,uint256)",trader,int(token,16)),16)==0
        tx("buy subsequent credit",gate,call_data("buy(uint256,uint256,uint160)",10*10**18,1,limit),trader)
        tx("fixture pause vault",simd,call_data("setPaused(bool)","true"))
        shares=int(read(simd,"balanceOf(address)",trader),16)
        tx("buy credit revert fallback",gate,call_data("buy(uint256,uint256,uint160)",10*10**18,1,limit),trader)
        assert int(read(simd,"balanceOf(address)",trader),16)==shares
        tx("fixture unpause vault",simd,call_data("setPaused(bool)","false"))
        balance=int(read(token,"balanceOf(address)",trader),16)
        tx("submitSell",gate,call_data("submitSell(uint256,string)",balance//10,"Rent is due; I will keep the rest."),trader)
        # Test-only oracle shim: production EIP-712/signature conformance is covered independently in forge.
        signer=deploy("GasOracleSigner")
        rpc("anvil_setCode",["0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982",rpc("eth_getCode",[signer,"latest"])])
        submitted=cast("keccak","Submitted(uint256,address,bytes32,uint256,uint256,uint256,string)")
        def request_id(receipt):
            return next(log["topics"][3] for log in receipt["logs"] if log["address"].lower()==gate.lower() and log["topics"][0]==submitted)
        def verdict(request,yes,nonce):
            now=int(rpc("eth_getBlockByNumber",["latest",False])["timestamp"],16)
            zero="0x"+"00"*32
            fields=["0x"+word(nonce),1,zero,0,"0x"+word(int(yes)),0,0,0,zero,zero,30,17,17,now,now+3600]
            a="("+",".join(map(str,fields))+")"
            receipt=tx("oracle approve" if yes else "oracle deny",INTAKE,call_data(
                "deliver(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)",request,a,"0x"))
            assert int(read(gate,"consumed(bytes32)","0x"+word(nonce)),16)==1
            return receipt
        # Timeout without a verdict: retry must succeed without an oracle signature.
        latest=int(rpc("eth_getBlockByNumber",["latest",False])["timestamp"],16)
        rpc("evm_setNextBlockTimestamp",[latest+1201]);rpc("evm_mine")
        tx("clearNoVerdict",gate,call_data("clearNoVerdict()"),trader)
        retry=tx("submitSell retry",gate,call_data("submitSell(uint256,string)",balance//10,"The rent is still due."),trader)
        verdict(request_id(retry),False,1)
        denied_id=int(read(gate,"nextPleaId()"),16)-1
        appealed=tx("appeal",gate,call_data("appeal(uint256,uint256,string)",denied_id,balance//10,"Please reconsider; I will keep the rest."),trader)
        verdict(request_id(appealed),True,2)
        tx("executeSell",gate,call_data("executeSell(uint256)",0),trader)
        tx("rebalance",hook,call_data("rebalance()"),keeper)
        # One-account double-hashed distribution, claimed by its recipient.
        leaf=cast("keccak",cast("keccak","0x"+word(keeper)+word(10**18)))
        tx("setMerkleRoot",distributor,call_data("setMerkleRoot(bytes32)",leaf))
        tx("claim",distributor,call_data("claim(address,uint256,bytes32[])",keeper,10**18,"[]"),keeper)
        last=int(read(gate,"lastVerdictAt()"),16)
        rpc("evm_setNextBlockTimestamp",[last+33*3600+1]);rpc("evm_mine")
        tx("killCabal",gate,call_data("killCabal()"),keeper)
        tx("sellFreely",gate,call_data("sellFreely(uint256,uint256)",balance//20,0),trader)
        print(json.dumps({"fork":args.fork_url or False,"baseBlock":int(fork_block["number"],16),"hardfork":"osaka","transactions":records},indent=2))
    finally:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill();process.wait()

if __name__=="__main__": main()
