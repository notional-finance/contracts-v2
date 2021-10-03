data = {
	"contractName": "ERC1155Action",
		 "main_table": {
			"tableHeader":[
				"Test name",
				"Result",
				"Time(sec)",
				"Dump"
			],
			"contractResult":[
				{
					 "tableRow": {
						"ruleName": "accountContextMustBeReadAndWrittenExactlyOnce",
						"result": "UNKNOWN",
						"time": "4650",
						"graph_link": "Report-accountContextMustBeReadAndWrittenExactlyOnce.html"
					},
					"isMultiRule": true
				}
			]

		},
		 "sub_tables": {
			"tableHeader":[
				"Function name",
				"Result",
				"Time(secs)",
				"Dump"
			],
			"functionResults":[
				{
					"ruleName": "accountContextMustBeReadAndWrittenExactlyOnce",
					"tableBody":[
						{
							 "tableRow": {
								"funcName": "safeBatchTransferFrom(address,address,uint256[],uint256[],bytes)",
								"result": "TIMEOUT",
								"time": "2370",
								"graph_link": "Report-accountContextMustBeReadAndWrittenExactlyOnce-safeBatchTransferFromLPADRCADRCU256LBRBCU256LBRBCbytesRP.html"
							},
							 "callResolutionTable": {
								"tableHeader":[
									"Caller",
									"Callee",
									"Summary"
								],
								"callResolution":[
									{
										 "tableRow": {
											"caller": "FreeCollateralExternal.checkFreeCollateralAndRevert",
											"callee": "AssetRateAdapter(rateOracle).getExchangeRateStateful()",
											"summmary": "ALL NonDet summary @ shellyActions.spec:20:34",
											"comments":[
												{
													"havoc type": "only the return value"
												},
												{
													"use decision": "specification"
												}
											]
										}
									},
									{
										 "tableRow": {
											"caller": "SettleAssetsExternal.settleAssetsAndFinalize",
											"callee": "AssetRateAdapter(rateOracle).getExchangeRateStateful()",
											"summmary": "ALL NonDet summary @ shellyActions.spec:20:34",
											"comments":[
												{
													"havoc type": "only the return value"
												},
												{
													"use decision": "specification"
												}
											]
										}
									},
									{
										 "tableRow": {
											"caller": "SettleAssetsExternal.settleAssetsAndReturnPortfolio",
											"callee": "AssetRateAdapter(rateOracle).getExchangeRateStateful()",
											"summmary": "ALL NonDet summary @ shellyActions.spec:20:34",
											"comments":[
												{
													"havoc type": "only the return value"
												},
												{
													"use decision": "specification"
												}
											]
										}
									}
								]
							},
							 "callResolutionWarningsTable": {
								"tableHeader":[
									"Caller",
									"Callee",
									"Summary"
								],
								"callResolutionWarnings":[
									{
										 "tableRow": {
											"caller": "FreeCollateralExternal.checkFreeCollateralAndRevert",
											"callee": "AggregatorV2V3Interface(rateOracle).latestRoundData()",
											"summmary": "UNRESOLVED Auto summary",
											"comments":[
												{
													"havoc type": "only the return value"
												},
												{
													"use decision": "default"
												}
											]
										}
									},
									{
										 "tableRow": {
											"caller": "FreeCollateralExternal.checkFreeCollateralAndRevert",
											"callee": "AssetRateAdapter(ar.rateOracle).getAnnualizedSupplyRate()",
											"summmary": "UNRESOLVED Auto summary",
											"comments":[
												{
													"havoc type": "only the return value"
												},
												{
													"use decision": "default"
												}
											]
										}
									},
									{
										 "tableRow": {
											"caller": "ERC1155Action.safeBatchTransferFrom",
											"callee": "address(this).call{value: msg.value}(data)",
											"summmary": "UNRESOLVED Auto summary",
											"comments":[
												{
													"havoc type": "all contracts except ERC1155Action (ce4604a000000000000000000000002a)"
												},
												{
													"use decision": "default"
												}
											]
										}
									},
									{
										 "tableRow": {
											"caller": "ERC1155Action.safeBatchTransferFrom",
											"callee": "IERC1155TokenReceiver(to).onERC1155BatchReceived(...)",
											"summmary": "UNRESOLVED Auto summary",
											"comments":[
												{
													"havoc type": "all contracts except ERC1155Action (ce4604a000000000000000000000002a)"
												},
												{
													"use decision": "default"
												}
											]
										}
									}
								]
							}
						}
,						{
							 "tableRow": {
								"funcName": "safeTransferFrom(address,address,uint256,uint256,bytes)",
								"result": "TIMEOUT",
								"time": "2280",
								"graph_link": "Report-accountContextMustBeReadAndWrittenExactlyOnce-safeTransferFromLPADRCADRCU256CU256CbytesRP.html"
							},
							 "callResolutionTable": {
								"tableHeader":[
									"Caller",
									"Callee",
									"Summary"
								],
								"callResolution":[
									{
										 "tableRow": {
											"caller": "FreeCollateralExternal.checkFreeCollateralAndRevert",
											"callee": "AssetRateAdapter(rateOracle).getExchangeRateStateful()",
											"summmary": "ALL NonDet summary @ shellyActions.spec:20:34",
											"comments":[
												{
													"havoc type": "only the return value"
												},
												{
													"use decision": "specification"
												}
											]
										}
									},
									{
										 "tableRow": {
											"caller": "SettleAssetsExternal.settleAssetsAndFinalize",
											"callee": "AssetRateAdapter(rateOracle).getExchangeRateStateful()",
											"summmary": "ALL NonDet summary @ shellyActions.spec:20:34",
											"comments":[
												{
													"havoc type": "only the return value"
												},
												{
													"use decision": "specification"
												}
											]
										}
									},
									{
										 "tableRow": {
											"caller": "SettleAssetsExternal.settleAssetsAndReturnPortfolio",
											"callee": "AssetRateAdapter(rateOracle).getExchangeRateStateful()",
											"summmary": "ALL NonDet summary @ shellyActions.spec:20:34",
											"comments":[
												{
													"havoc type": "only the return value"
												},
												{
													"use decision": "specification"
												}
											]
										}
									}
								]
							},
							 "callResolutionWarningsTable": {
								"tableHeader":[
									"Caller",
									"Callee",
									"Summary"
								],
								"callResolutionWarnings":[
									{
										 "tableRow": {
											"caller": "FreeCollateralExternal.checkFreeCollateralAndRevert",
											"callee": "AggregatorV2V3Interface(rateOracle).latestRoundData()",
											"summmary": "UNRESOLVED Auto summary",
											"comments":[
												{
													"havoc type": "only the return value"
												},
												{
													"use decision": "default"
												}
											]
										}
									},
									{
										 "tableRow": {
											"caller": "FreeCollateralExternal.checkFreeCollateralAndRevert",
											"callee": "AssetRateAdapter(ar.rateOracle).getAnnualizedSupplyRate()",
											"summmary": "UNRESOLVED Auto summary",
											"comments":[
												{
													"havoc type": "only the return value"
												},
												{
													"use decision": "default"
												}
											]
										}
									},
									{
										 "tableRow": {
											"caller": "ERC1155Action.safeTransferFrom",
											"callee": "address(this).call{value: msg.value}(data)",
											"summmary": "UNRESOLVED Auto summary",
											"comments":[
												{
													"havoc type": "all contracts except ERC1155Action (ce4604a000000000000000000000002a)"
												},
												{
													"use decision": "default"
												}
											]
										}
									},
									{
										 "tableRow": {
											"caller": "ERC1155Action.safeTransferFrom",
											"callee": "IERC1155TokenReceiver(to).onERC1155Received(msg.sender, from, id, amount, data)",
											"summmary": "UNRESOLVED Auto summary",
											"comments":[
												{
													"havoc type": "all contracts except ERC1155Action (ce4604a000000000000000000000002a)"
												},
												{
													"use decision": "default"
												}
											]
										}
									}
								]
							}
						}
,						{
							 "tableRow": {
								"funcName": "certorafallback_0()",
								"result": "SUCCESS",
								"time": "0",
								"graph_link": "Report-accountContextMustBeReadAndWrittenExactlyOnce-certorafallback_0LPRP.html"
							},
							 "callResolutionTable": {
								"tableHeader":[
									"Caller",
									"Callee",
									"Summary"
								],
								"callResolution":[

								]
							},
							 "callResolutionWarningsTable": {
								"tableHeader":[
									"Caller",
									"Callee",
									"Summary"
								],
								"callResolutionWarnings":[

								]
							}
						}
,						{
							 "tableRow": {
								"funcName": "setApprovalForAll(address,bool)",
								"result": "SUCCESS",
								"time": "0",
								"graph_link": "Report-accountContextMustBeReadAndWrittenExactlyOnce-setApprovalForAllLPADRCboolRP.html"
							},
							 "callResolutionTable": {
								"tableHeader":[
									"Caller",
									"Callee",
									"Summary"
								],
								"callResolution":[

								]
							},
							 "callResolutionWarningsTable": {
								"tableHeader":[
									"Caller",
									"Callee",
									"Summary"
								],
								"callResolutionWarnings":[

								]
							}
						}
					]

				}
			]

		},
		 "availableContractsTable": {
			"sectionName": "Available contracts",
			"tableHeader":[
				"Name",
				"Address",
				"Pre-state",
				"Methods"
			],
			"contractResult":[
				{
					 "tableRow": {
						"name": "ERC1155Action",
						"address": "ce4604a000000000000000000000002a",
						"pre_state": "{}",
						"methodsNames":[
							"certoraFunctionFinder65(int128)",
							"certoraFunctionFinder66(uint256)",
							"certoraFunctionFinder86(address,address)",
							"certoraFunctionFinder31(uint256,uint256,uint256,uint256)",
							"certoraFunctionFinder47(address,uint256,bytes32)",
							"certoraFunctionFinder63(int128,int128)",
							"certoraFunctionFinder64(int128)",
							"certoraFunctionFinder34(address,uint256)",
							"certoraFunctionFinder67(bytes32)",
							"certoraFunctionFinder46(address,uint256,uint256)",
							"certoraFunctionFinder30(int256,int256,int256,int256,uint256)",
							"certoraFunctionFinder68(bytes32,uint256)",
							"certoraFunctionFinder7(uint256,uint256)",
							"certoraFunctionFinder50(address,uint256,uint256,uint256)",
							"certoraFunctionFinder70(bytes32)",
							"certoraFunctionFinder33(int256,int256,int256,int256,int256,int256,uint256)",
							"certoraFunctionFinder49(uint256,uint256,uint256)",
							"certoraFunctionFinder69(bytes32,uint256,bool)",
							"safeBatchTransferFrom(address,address,uint256[],uint256[],bytes)",
							"certoraFunctionFinder32(uint256,uint256,uint256)",
							"certoraFunctionFinder48(uint256)",
							"certoraFunctionFinder71(uint256)",
							"certoraFunctionFinder1(uint256,uint256)",
							"certoraFunctionFinder57(int128)",
							"certoraFunctionFinder39(address,uint8,uint256)",
							"certoraFunctionFinder72(uint256)",
							"certoraFunctionFinder73(int256)",
							"certoraFunctionFinder54(int128,int128)",
							"certoraFunctionFinder74(int256,int256)",
							"certoraFunctionFinder36(address)",
							"certoraFunctionFinder51(uint256,uint256)",
							"certoraFunctionFinder80(int256,int256)",
							"certoraFunctionFinder35(address,int256,uint256)",
							"certoraFunctionFinder75(int256,int256)",
							"certoraFunctionFinder52(int256,uint256,uint256,uint256)",
							"certoraFunctionFinder76(int256,int256)",
							"isApprovedForAll(address,address)",
							"certoraFunctionFinder38(uint256)",
							"certoraFunctionFinder53(uint256)",
							"certoraFunctionFinder77(int256,int256)",
							"certoraFunctionFinder37(address)",
							"certoraFunctionFinder78(int256,int256)",
							"certoraFunctionFinder58(int256)",
							"certoraFunctionFinder83(address,uint256,uint256)",
							"certoraFunctionFinder55(int128,int128)",
							"certoraFunctionFinder79(int256)",
							"certoraFunctionFinder42(address,uint8,uint8,uint8,uint8,uint8)",
							"certoraFunctionFinder8(uint256,uint256)",
							"certoraFunctionFinder56(int128)",
							"pauseRouter()",
							"certoraFunctionFinder41(uint16,address)",
							"certoraFunctionFinder81(int256,int256)",
							"certoraFunctionFinder59(uint256)",
							"certoraFunctionFinder9(uint256,uint256)",
							"certoraFunctionFinder40(address,uint32)",
							"certoraFunctionFinder60(int128)",
							"owner()",
							"certoraFunctionFinder43(address,uint256,uint256,uint256,int256,bytes32)",
							"certoraFunctionFinder10(bytes18)",
							"certoraFunctionFinder61(int128)",
							"certoraFunctionFinder44(address,uint256)",
							"certoraFunctionFinder62(int128,int128)",
							"pauseGuardian()",
							"certoraFunctionFinder11(address,uint256)",
							"certoraFunctionFinder45(address,uint256,uint256)",
							"certoraFunctionFinder12(uint256,int256)",
							"safeTransferFrom(address,address,uint256,uint256,bytes)",
							"certoraFunctionFinder13(address,uint256,int256)",
							"certoraFunctionFinder16(uint256)",
							"certoraFunctionFinder17(uint256,uint256,uint256,uint256,uint256)",
							"balanceOf(address,uint256)",
							"certoraFunctionFinder5(uint256,uint256)",
							"decodeToAssets(uint256[],uint256[])",
							"certoraFunctionFinder14(address,uint256,uint256,uint256,uint256,uint256)",
							"certoraFunctionFinder15(address,uint256)",
							"certoraFunctionFinder84(address,address)",
							"certoraFunctionFinder18(uint256,uint256)",
							"certoraFunctionFinder85(address,uint256)",
							"certoraFunctionFinder19(uint256,uint256,uint256)",
							"certoraFunctionFinder22(uint256)",
							"certoraFunctionFinder82(uint256,uint256,uint256)",
							"certoraFunctionFinder0(uint256,uint256)",
							"certoraFunctionFinder2(uint256,uint256)",
							"certoraFunctionFinder23(uint256)",
							"certoraFunctionFinder20(uint256,uint256)",
							"supportsInterface(bytes4)",
							"certoraFunctionFinder4(uint256,uint256)",
							"certoraFunctionFinder21(uint256)",
							"balanceOfBatch(address[],uint256[])",
							"certoraFunctionFinder24(uint256,uint256,uint256)",
							"encodeToId(uint16,uint40,uint8)",
							"certoraFunctionFinder25(uint256,uint256,uint256)",
							"setApprovalForAll(address,bool)",
							"certoraFunctionFinder26(int256,int256,int256,int256,int256)",
							"certoraFunctionFinder28(int256)",
							"certoraFunctionFinder3(uint256,uint256)",
							"certoraFunctionFinder6(uint256,uint256)",
							"certoraFunctionFinder29(uint256,uint256)",
							"certoraFunctionFinder27(int256,uint256,int256,int256,uint256)"
						]
					}
				},
				{
					 "tableRow": {
						"name": "FreeCollateralExternal",
						"address": "ce4604a0000000000000000000000028",
						"pre_state": "{}",
						"methodsNames":[
							"getFreeCollateralView(address)",
							"getLiquidationFactors(address,uint256,uint256)",
							"checkFreeCollateralAndRevert(address)"
						]
					}
				},
				{
					 "tableRow": {
						"name": "SettleAssetsExternal",
						"address": "ce4604a0000000000000000000000029",
						"pre_state": "{}",
						"methodsNames":[
							"settleAssetsAndFinalize(address,(uint40,bytes1,uint8,uint16,bytes18))",
							"settleAssetsAndReturnPortfolio(address,(uint40,bytes1,uint8,uint16,bytes18))",
							"settleAssetsAndReturnAll(address,(uint40,bytes1,uint8,uint16,bytes18))",
							"settleAssetsAndStorePortfolio(address,(uint40,bytes1,uint8,uint16,bytes18))"
						]
					}
				}
			]
		}
	}