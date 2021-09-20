methods {
    getOwner() returns address envfree
    getPauseGuardian() returns address envfree
    getPauseRouter() returns address envfree
}

rule onlyOwnerCanUpdateGovernace(method f)
// 0x3659cfe6 == upgradeTo
// 0x4f1ef286 == upgradeToAndCall
filtered { f -> !(f.isView || f.selector == 0x3659cfe6 || f.selector == 0x4f1ef286) }
description "all methods exposed on governance can only be called by the owner"
{
    env e;
    calldataarg arg;
    address ownerBefore = getOwner();
    // Any non reverting stateful call
    sinvoke f(e, arg);
    assert e.msg.sender == ownerBefore, "Non owner address invoked governance method";
}

rule onlyAuthorizedCanPauseSystem(method f)
// 0x3659cfe6 == upgradeTo
// 0x4f1ef286 == upgradeToAndCall
filtered { f -> (f.selector == 0x3659cfe6 || f.selector == 0x4f1ef286) }
description "only authorized can pause system"
{
    env e;
    calldataarg arg;
    address owner = getOwner();
    address pauseGuardian = getPauseGuardian();
    // Any non reverting stateful call
    sinvoke f(e, arg);
    assert (e.msg.sender == owner) || (e.msg.sender == pauseGuardian);
}