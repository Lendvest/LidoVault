import math
# x = '2'
# y = "0" * 27
# print(x+y)

# print(len("6000000000000000000000000000"))

# print("3"*27)
# print("6"*27)

# print(int("6"*27) * int("3"*27))

# print(len(str((int("6"*27) * int("3"*27)))))

# print(0.5 * 10**27)

# print(1 * 10 ** 27)
# print((int("6"*27) * int("3"*27)) + 0.5 * 10**27)

# def rayMul(x,y):
#     half_ray = 0.5 * 10**27
#     ray = 1 * 10**27
#     print(((x * y) + half_ray ) / (ray))
#     return ((x * y) + half_ray ) / (ray)


RAY = 10**27
HALF_RAY = RAY // 2
MAX_UINT256 = 2**256 - 1
MAX_UINT256_MINUS_HALF_RAY = MAX_UINT256 - HALF_RAY


def rayMul(x, y):
    # Overflow check similar to the Solidity version
    if y > 0 and x > MAX_UINT256_MINUS_HALF_RAY // y:
        raise OverflowError("Operation would cause an overflow")
    
    # Perform the multiplication with ray precision and rounding half up
    z = (x * y + HALF_RAY) // RAY
    return z
    
    


def rayDiv(x, y):
    # Check for division by zero
    if y == 0:
        raise ZeroDivisionError("Division by zero")
    
    # Overflow protection similar to the Solidity version
    temp_z = y // 2  # Temporary assignment to simulate saving gas
    
    # Overflow check (translated from the Solidity version)
    if x > (MAX_UINT256 - temp_z) // RAY:
        raise OverflowError("Operation would cause an overflow")
    
    # Perform the division with ray precision and rounding half up
    z = (RAY * x + temp_z) // y
    return z

# Supply Scenrio

pool = 0 # supplier balance on pool already
print("previous balance of user on pool",pool)

amount = 5 * 10**18 # supplier amount
print("user deposit this much amount",amount)
normalizeIncome  = 1035208113384808450829728083

pool = pool + rayDiv(amount,normalizeIncome)

print("amount in pool become for accounting",pool)
print("then morpho called the deposit with this amount")


#  withdraw
print("######3Withdraw###########3")
print("balance of supplier in pool",pool)

user_with_amount = 5 * 10**18 

print("withdrawing",user_with_amount)



print("Morpho calculating how much amount we have to give back to user")
remaining_to_with = user_with_amount
to_withdraw = min(rayMul(pool,normalizeIncome), remaining_to_with)
print("min to withdraw")
print(to_withdraw)
remaining_to_with = remaining_to_with - to_withdraw

pool = pool - min(pool,rayDiv(to_withdraw,normalizeIncome))

# supplierSupplyBalance.onPool -= Math.min(
#         vars.onPoolSupply,
#         vars.toWithdraw.rayDiv(vars.poolSupplyIndex)
#     );


#  it should only be zero if to_withdraw and remaining_to_with are same
if remaining_to_with == 0:
    print("if to_withdraw and remaining_to_with are same")
    print("the amount is subtracting from the pool",min(pool,rayDiv(to_withdraw,normalizeIncome)))
    print("pool amount",pool)
    print("we are withdrawing ",to_withdraw)
    print("we are sending this amount to user",user_with_amount)
    
    # need to figure out this function
    #  _updateSupplierInDS(_poolToken, _supplier);
    
    


# rayMul(amount,normalizeIncome)


# print(len(str(normalizeIncome)))


# print(len(str(10352081133848084508)))

