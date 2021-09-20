rule r (method f) {
	env e; calldataarg arg;
	f(e,arg);
	assert false;

}
