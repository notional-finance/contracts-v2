#!/bin/bash
python3 -m venv venv
source venv/bin/activate
pip3 install -r requirements.txt
brownie pm install compound-finance/compound-protocol@2.8.1
brownie pm install OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7

brownie compile
