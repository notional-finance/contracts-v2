rule onlyOwnerCanUpdateGovernace {
    env e;
    method f;
    require !f.isView;
    calldataarg arg;
    address ownerBefore = getOwner();
    // Any non reverting stateful call
    sinvoke f(e, arg);
    assert e.msg.sender == ownerBefore, "Non owner address invoked governance method";
}

