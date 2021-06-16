methods {
    latestAnswer() returns int envfree
}

rule setAnswer(int a) {
    env e;
    setAnswer(e, a);
    assert latestAnswer() == a, "Answer is not set properly";
}
