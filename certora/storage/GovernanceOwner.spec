methods {
    getOwner() returns address envfree
}

rule onlyOwnerCanUpdateGovernace(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg arg;
    address ownerBefore = getOwner();
    // Any non reverting stateful call
    sinvoke f(e, arg);
    assert e.msg.sender == ownerBefore, "Non owner address invoked governance method";
}