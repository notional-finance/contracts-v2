import pytest
from brownie.test import given, strategy


@pytest.fixture(scope="module", autouse=True)
def mock(MockPrimeCash, accounts):
    return MockPrimeCash.deploy(accounts[0], {"from": accounts[0]})


def test_neg_change(mock):
    # 100 units of additional debt
    assert mock.negChange(100, -100) == 100
    assert mock.negChange(0, -100) == 100

    # 100 units of additional debt
    assert mock.negChange(-100, -200) == 100

    # 100 units of debt reduction
    assert mock.negChange(-100, 100) == -100
    assert mock.negChange(-100, 0) == -100

    # 100 units of debt reduction
    assert mock.negChange(-200, -100) == -100


@given(
    startBalance=strategy("uint", min_value=0, max_value=100_000e8),
    endBalance=strategy("uint", min_value=0, max_value=100_000e8),
)
def test_neg_change_both_positive(mock, startBalance, endBalance):
    # Always returns zero when both are positive
    assert mock.negChange(startBalance, endBalance) == 0


@given(
    startBalance=strategy("int", min_value=-100_000e8, max_value=0),
    endBalance=strategy("int", min_value=-100_000e8, max_value=0),
)
def test_neg_change_both_negative(mock, startBalance, endBalance):
    assert mock.negChange(startBalance, endBalance) == startBalance - endBalance


@given(
    startBalance=strategy("int", min_value=0, max_value=100_000e8),
    endBalance=strategy("int", min_value=-100_000e8, max_value=0),
)
def test_neg_change_start_positive_end_negative(mock, startBalance, endBalance):
    assert endBalance + mock.negChange(startBalance, endBalance) == 0


@given(
    startBalance=strategy("int", min_value=-100_000e8, max_value=0),
    endBalance=strategy("int", min_value=0, max_value=100_000e8),
)
def test_neg_change_start_negative_end_positive(mock, startBalance, endBalance):
    # Signifies complete reduction in debt balance
    assert mock.negChange(startBalance, endBalance) == startBalance
