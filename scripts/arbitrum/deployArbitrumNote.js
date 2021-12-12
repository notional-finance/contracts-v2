require('dotenv').config()
const { Bridge } = require('arb-ts')
const ArbitrumL2NoteERC20 = require('./ArbitrumL2NoteERC20.json')
const ArbitrumL1NoteERC20 = require('./ArbitrumL1NoteERC20.json')
const nProxy = require('./nProxy.json')
const ethers = require('ethers')

const ARBITRUM_CONFIG = {
    "rinkeby": {
        "customGateway": "0x917dc9a69F65dC3082D518192cd3725E1Fa96cA2",
        "gatewayRouter": "0x70C143928eCfFaf9F5b406f7f4fC28Dc43d68380",
        "noteToken": "0x72Ec9dE3eFD22552b6dc17142EAd505A48940D4E"
    },
    "arbitrum-testnet": {
        "l1NetworkName": "rinkeby",
        "customGateway": "0x9b014455AcC2Fe90c52803849d0002aeEC184a06",
        "gatewayRouter": "0x9413AD42910c1eA60c737dB5f58d1C504498a3cD",
    },
}

async function main() {
  const ethSigner = new ethers.VoidSigner(
    process.env.RINKEBY_PKEY,
    new ethers.providers.JsonRpcProvider(process.env.RINKEBY_HOST)
  )
  const arbSigner = new ethers.Wallet(
    process.env.ARBITRUM_PKEY,
    new ethers.providers.JsonRpcProvider(process.env.ARBITRUM_HOST)
  )

  const NoteL2Factory = new ethers.ContractFactory(ArbitrumL2NoteERC20['abi'], ArbitrumL2NoteERC20['bytecode'], arbSigner)
  const nProxyFactory = new ethers.ContractFactory(nProxy['abi'], nProxy['bytecode'], arbSigner)
  const arbL2Impl = await NoteL2Factory.deploy(
    ARBITRUM_CONFIG['arbitrum-testnet']['customGateway'],
    ARBITRUM_CONFIG['rinkeby']['noteToken']
  )

  // Will set the deployer as the owner
  const initializeCallData = await arbL2Impl.populateTransaction.initialize([], [], arbSigner.address)
  console.log(initializeCallData)

  const proxy = await nProxyFactory.deploy(arbL2Impl.address, initializeCallData.data)
  console.log("Arbitrum Token Address:")
  console.log(proxy.address)

  const bridge = await Bridge.init(ethSigner, arbSigner)
  // Below here is taken from: https://github.com/OffchainLabs/arbitrum-tutorials/tree/master/packages/custom-token-bridging
  // We set how many bytes of calldata is needed to create the retryable tickets on L2
  const customBridgeCalldataSize = 1000
  const routerCalldataSize = 1000
  
  /**
  * Base submission cost is a special cost for creating a retryable ticket.
  * We query the submission price using a helper method; the first value returned tells us the best cost of
  * our transaction; that's what we'll be using.
  */
  
  const [ _submissionPriceWeiForCustomBridge, ] = await bridge.l2Bridge.getTxnSubmissionPrice(customBridgeCalldataSize)
  const [ _submissionPriceWeiForRouter, ] = await bridge.l2Bridge.getTxnSubmissionPrice(routerCalldataSize)
  console.log(
    `Current retryable base submission prices for custom
    bridge and router are: ${_submissionPriceWeiForCustomBridge.toString(), _submissionPriceWeiForRouter.toString()}`
  )

  // For the L2 gas price, we simply query it from the L2 provider, as we would when using L1
  const gasPriceBid = await bridge.l2Provider.getGasPrice()
  console.log(`L2 gas price: ${gasPriceBid.toString()}`)

  // For the gas limit, we'll simply use a hard-coded value (for more precise / dynamic estimates, see the
  // estimateRetryableTicket method in the NodeInterface L2 "precompile")
  const maxGasCustomBridge = 10000000
  const maxGasRouter = 10000000

  // With these three values (base submission price, gas price, gas kinit), we can calculate the total
  // callvalue we'll need our L1 transaction to send to L2
  const valueForGateway = _submissionPriceWeiForCustomBridge.add(gasPriceBid.mul(maxGasCustomBridge))
  const valueForRouter = _submissionPriceWeiForRouter.add(gasPriceBid.mul(maxGasRouter))
  const callValue = valueForGateway.add(valueForRouter)

  console.log(`valueForGateway and valueForRouter: ${valueForGateway.toString()} ${valueForRouter.toString()}`)
  console.log(
    `Registering the custom token on L2 with ${callValue.toString()} callValue for L2 fees:`
  )

  // Deploy the L1 Upgraded NOTE Token
  const NoteL1Factory = new ethers.ContractFactory(ArbitrumL1NoteERC20['abi'], ArbitrumL1NoteERC20['bytecode'], ethSigner)
  const L1NoteImpl = await NoteL1Factory.deploy(
    ARBITRUM_CONFIG["rinkeby"]["customGateway"], ARBITRUM_CONFIG["rinkeby"]["gatewayRouter"]
  )
  const registerTokenCalldata = await L1NoteImpl.populateTransaction.registerTokenOnL2(
    proxy.address,
    _submissionPriceWeiForCustomBridge,
    _submissionPriceWeiForRouter,
    maxGasCustomBridge,
    maxGasRouter,
    gasPriceBid,
    valueForGateway,
    valueForRouter
  )
  console.log("Register token calldata")
  console.log(registerTokenCalldata.toString())
  console.log("Submission Value (ETH)")
  console.log(callValue.toString())
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
