%lang starknet

# @author StarkDefi
# @license MIT

from dex.interfaces.IERC20 import IERC20
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.uint256 import (
    Uint256,
    uint256_check,
    uint256_le,
    uint256_not,
    uint256_eq,
    uint256_sqrt,
    uint256_unsigned_div_rem,
    uint256_lt,
)
from dex.libraries.safemath import SafeUint256
from starkware.cairo.common.math import assert_not_zero, assert_le, assert_nn, assert_eq
from starkware.cairo.common.bool import TRUE, FALSE
from starkware.starknet.common.syscalls import (
    get_caller_address,
    get_contract_address,
    get_block_number,
)


#
# Events
#

@event
func Deposit(event_name : felt, user : felt, pid : Uint256, amount : Uint256):
end

@event
func Withdraw(event_name : felt, user : felt, pid : Uint256, amount : Uint256, to : felt):
end

@event
func EmergencyWithdraw(event_name : felt, user : felt, pid : Uint256, amount : Uint256):
end

@event
func Harvest(event_name : felt, user : felt, pid : Uint256, amount : Uint256):
end

@event
func LogPoolAddition(event_name : felt, pid : Uint256, allocPoint : Uint256, lpToken : felt):
end

@event
func LogSetPool(event_name : felt, pid : Uint256, allocPoint : Uint256):
end

@event
func LogUpdatePool(event_name : felt, pid : Uint256, lastRewardBlock : Uint256, lpSupply : Uint256, accSDPerShare : Uint256):
end




#
# Storage
#

@storage_var
func owner() -> (owner_address : felt):
end

# Structs

# Information about a user's allocated amount of tokens
struct User:
    member amount : Uint256
    member rewardDebt : Uint256
end

# Information about a pool
struct PoolInfo:
    member lastRewardBlock : Uint256
    member accStarkDefiTokenPerShare : Uint256
    member lpToken : felt
    member allocPoint : Uint256
end

let (local all_pools_info : PoolInfo*) = alloc()
let (local all_lp_tokens :  felt*) = alloc()

@storage_var
func _pool_count() -> (size : Uint256):
end

@storage_var
func _lp_tokens_count() -> (size : Uint256):
end

@storage_var
func _user_info(user : felt, pid : Uint256) -> (user : User):
end

@storage_var
func _dev_address() -> (address: felt):
end

@storage_var
func _stark_defi_token() -> (address: felt):
end

@storage_var
func _total_allocation_points() -> (points: Uint256):
end

@storage_var
func _stark_defi_token_per_block() -> (amount: Uint256):
end


#
# Constructor
#

@constructor
func constructor{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    dev_address : felt, stark_defi_token : felt, stark_defi_token_per_block : Uint256,
):
    with_attr error_message("invalid stark_defi_token address"):
        assert_not_zero(_stark_defi_token)
    end
    
    let (owner_address) = get_caller_address()
    owner.write(owner_address)

    _stark_defi_token.write(stark_defi_token)
    _dev_address().write(dev_address)
    _stark_defi_token_per_block.write(stark_defi_token_per_block)
    _total_allocation_points().write(Uint256(0))

    return ()
end


#
# Getters
#
@view
func poolLength{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> ( length : Uint256 ):
    length = _pool_count().read()
    return (length)
end

@view
func getMultiplier{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    fromBlock : Uint256, toBlock : Uint256
) -> (multiplier : Uint256):
    # Get reward multiplier between two block timestamps
    with with_attr error_message("toBlock has to be larger than fromBlock"):
        assert_le(toBlock, fromBlock)
    end

    let (multiplier) = toBlock - fromBlock
    return (multiplier)
end

@view
func pendingStarkDefiTokens{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    pid : Uint256, user : felt
) -> (amount : Uint256):
    
    let (this_address) = get_contract_address()

    let (user_info) = _user_info.read(user, pid)
    let (pool) = all_pools_info.read(pid)

    let (acc_stark_defi_token_per_share) = pool.accStarkDefiTokenPerShare
    let (lp_token) = pool.lpToken
    let (lp_supply) = IERC20.balanceOf(contract_address=lp_token, account=this_address)

    if Uint256(get_block_number()) > pool.lastRewardBlock and lp_supply > Uint256(0):
        let (multiplier) = getMultiplier(pool.lastRewardBlock, Uint256(get_block_number()))
        let (reward_amount) = multiplier * _stark_defi_token_per_block().read() * pool.allocPoint / _total_allocation_points().read()
        acc_stark_defi_token_per_share = acc_stark_defi_token_per_share + reward_amount * 1e12 / lp_supply
    
    let (amount) = ( user_info.amount * acc_stark_defi_token_per_share / 1e12 ) - user_info.rewardDebt
    
    return (amount)

end


#
# Externals
#

# To add a new LP token to the pool, do not add the same lp token more than once
@external
func add{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    allocPoints : Uint256, lpToken : Uint256, _withUpdate : bool
):
    let (caller) = get_caller_address()
    with_attr error_message("owner only"):
        assert_eq(owner.read(), caller)
    end

    with_attr error_message(
            "allocPoints must be positive. Got: {allocPoints}."):
        assert_nn(allocPoints)
    end

    if _withUpdate == TRUE:
        mass_update_pools()
    end

    let (total_allocated_points) = _total_allocation_points.read()

    _total_allocation_points.write(total_allocated_points + allocPoints)

    let (next_pool) = _pool_count().read()

    let (lastRewardBlock) = Uint256(get_block_number())
    assert [all_pools_info + next_pool ] = PoolInfo(
        lastRewardBlock : lastRewardBlock,
        accStarkDefiTokenPerShare : Uint256(0),
        lpToken : lpToken,
        allocPoint : allocPoints
    )

    let (next_lp_token) = _lp_tokens_count().read()
    assert [all_lp_tokens + next_lp_token ] = lpToken



    _pool_count.write(next_pool + 1)
    _lp_tokens_count.write(next_lp_token + 1)

    # "add" written as hexidecimal for event output name
    LogPoolAddition.emit(616464, pid, allocPoints, lpToken)

    return()
end

# Update the given pool's allocation point
@external
func set{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    pid : Uint256, allocPoints : Uint256, _withUpdate : bool
):

    let (caller) = get_caller_address()
    with_attr error_message("owner only"):
        assert_eq(owner.read(), caller)
    end

    with_attr error_message(
            "allocPoints must be positive. Got: {allocPoints}."):
        assert_nn(allocPoints)
    end

    if _withUpdate == TRUE:
        mass_update_pools()
    end

    let (total_allocated_points) = _total_allocation_points.read()
    let (old_alloc_points) = all_pools_info[pid].allocPoint.read()
    let (new_alloc_points) = total_allocated_points - old_alloc_points + allocPoints
    _total_allocation_points.write(new_alloc_points)
    all_pools_info[pid].allocPoint.write(allocPoints)

    # "set" written as hexidecimal for event output name
    LogPoolSet.emit(736574, pid, allocPoints)

    return()
end


# Update reward values for all pools.
@external
func mass_update_pools{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}():
    recursive_update_pools(0)
end

@external
func recursive_update_pools{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    pid : Uint256
):
    let (next_pool) = pid + 1
    if next_pool <= _pool_count().read():
        update_pool(next_pool)
        recursive_update_pools(next_pool)
    end
    return()
end

# Update the given pool's reward values
@external
func update_pool{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    pid : Uint256
) -> (pool : PoolInfo):
    let pool = all_pools_info.read(pid)
    if Uint256(get_block_number()) <= pool.lastRewardBlock:
        return(pool)
    end
    let (lp_supply) = IERC20.balanceOf(contract_address=pool.lpToken, account=get_contract_address())
    
    if lp_supply == 0:
        pool.lastRewardBlock.write(Uint256(get_block_number()))
        # "update" written as hexidecimal for event output name
        LogPoolUpdate.emit(757175, pid, pool.lastRewardBlock, lp_supply, pool.accStarkDefiTokenPerShare)
        return(pool)
    end
    let (multiplier) = getMultiplier(pool.lastRewardBlock, Uint256(get_block_number()))
    let (reward_amount) = multiplier * _stark_defi_token_per_block().read() * pool.allocPoint / _total_allocation_points().read()
    let (lastRewardBlock) = Uint256(get_block_number())

    IERC20.mint(contract_address=_stark_defi_token.read(), account=_dev_address.read(), amount=reward_amount/10)
    IERC20.mint(contract_address=_stark_defi_token.read(), account=get_contract_address(), amount=reward_amount)

    let (newAccStarkDefiTokenPerShare) = pool.accStarkDefiTokenPerShare + reward_amount * 1e12 / lp_supply
    pool.accStarkDefiTokenPerShare.write(newAccStarkDefiTokenPerShare)
    pool.lastRewardBlock.write(lastRewardBlock)

    # "update" written as hexidecimal for event output name
    LogPoolUpdate.emit(757175, pid, lastRewardBlock, lp_supply, newAccStarkDefiTokenPerShare)

    return(pool)
end

# Deposit LP tokens to Stark Defi farm for stark defi token allocation
@external
func deposit{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    amount : Uint256, pid : Uint256
):
    let (caller) = get_caller_address()

    with_attr error_message(
            "amount must be positive. Got: {amount}."):
        assert_nn(amount)
    end
    let pool = update_pool(pid)
    let user_info = _user_info.read(caller, pid)

    if user_info.amount > 0:
        let pending = ( user_info.amount * pool.accStarkDefiTokenPerShare / 1e12 ) - user_info.rewardDebt
        _safe_transfer_stark_defi_tokens(caller,  pending)
    end
    IERC20.safe_transfer_from(contract_address=pool.lpToken , from=caller, to=get_contract_address(), amount=amount)
    user_info.amount = user_info.amount + amount
    user_info.rewardDebt = user_info.amount * pool.accStarkDefiTokenPerShare / 1e12
    _user_info.write(caller, pid, user_info)

    # "deposit" written as hexidecimal for event output name
    Deposit.emit(6465706F736974, caller, pid, amount)

    return()
end

# Withdraw some LP tokens from Stark Defi farm and harvest proceeds
@external
func withdraw_and_harvest{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    amount : Uint256, pid : Uint256, to : felt
):
    let (caller) = get_caller_address()
    let pool = update_pool(pid)
    let user_info = _user_info.read(caller, pid)
    with_attr error_message(
            "amount must be positive. Got: {amount}."):
        assert_nn(amount)
    end
    with_attr error_message(
            "amount must be less than or equal to {user_info.amount}."):
        assert_le(amount, user_info.amount)
    end
    
    let (pending) = ( user_info.amount * pool.accStarkDefiTokenPerShare / 1e12 ) - user_info.rewardDebt
    _safe_transfer_stark_defi_tokens(to,  pending)

    user_info.amount = user_info.amount - amount
    user_info.rewardDebt = ( user_info.amount * pool.accStarkDefiTokenPerShare / 1e12 ) - ( amount * pool.accStarkDefiTokenPerShare / 1e12 )
    _user_info.write(caller, pid, user_info)

    IERC20.safe_transfer(contract_address=pool.lpToken, to=to, amount=amount)

    # "withdraw" written as hexidecimal for event output name
    Withdraw.emit(7769746864726177, caller, pid, amount, to)

    # "harvest" written as hexidecimal for event output name
    Harvest.emit(68617276657374, caller, pid, amount)

    return()
end

# Withdraw some LP tokens from Stark Defi farm without harvesting proceeds for that amount
@external
func withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    amount : Uint256, pid : Uint256, to : felt
):
    let (caller) = get_caller_address()
    let pool = update_pool(pid)
    let user_info = _user_info.read(caller, pid)
    with_attr error_message(
            "amount must be positive. Got: {amount}."):
        assert_nn(amount)
    end
    with_attr error_message(
            "amount must be less than or equal to {user_info.amount}."):
        assert_le(amount, user_info.amount)
    end

    user_info.amount = user_info.amount - amount
    user_info.rewardDebt = user_info.rewardDebt -  ( amount * pool.accStarkDefiTokenPerShare / 1e12 )
    _user_info.write(caller, pid, user_info)

    IERC20.safe_transfer(contract_address=pool.lpToken, to=to, amount=amount)

    # "withdraw" written as hexidecimal for event output name
    Withdraw.emit(7769746864726177, caller, pid, amount, to)
    return()
end

# Harvest proceeds of Stark Defi farm to 'to' address without removing LP tokens
@external
func harvest{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    pid : Uint256, to : felt
):
    let (caller) = get_caller_address()
    let pool = update_pool(pid)
    let user_info = _user_info.read(caller, pid)
    
    let (pending) = ( user_info.amount * pool.accStarkDefiTokenPerShare / 1e12 ) - user_info.rewardDebt
    _safe_transfer_stark_defi_tokens(caller,  pending)

    user_info.amount = user_info.amount - amount
    user_info.rewardDebt = user_info.amount * pool.accStarkDefiTokenPerShare / 1e12
    _user_info.write(caller, pid, user_info)

    # "harvest" written as hexidecimal for event output name
    Harvest.emit(68617276657374, caller, pid, amount)
    return()
end

# Withdraw all LP tokens from Stark Defi farm/pool without caring about rewards
@external
func emergency_withdraw{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    pid : Uint256
):
    let (caller) = get_caller_address()
    let pool = all_pools_info.read(pid)
    let user_info = _user_info.read(caller, pid)
    let amount = user_info.amount
    IERC20.safe_transfer(contract_address=pool.lpToken, to=caller, amount=amount)

    # "emergencywithdraw" written as hexidecimal for event output name
    EmergencyWithdraw.emit(656D657267656E63797769746864726177, caller, pid, amount)

    user_info.amount = 0
    user_info.rewardDebt = 0
    return()
end

# Safe transafer of stark defi tokens from the pool incase rounding errors occured during the update processes
@internal
func _safe_transfer_stark_defi_tokens{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    to : felt, amount : Uint256
):
    let balance = IERC20.balanceOf(contract_address=_stark_defi_token.read(), account=get_contract_address())
    if amount > balance:
        amount = balance
    end
    IERC20.transfer(contract_address=_stark_defi_token.read(), account=to, amount=amount)
    return()
end

# Set the dev address
@external
func update_devaddress{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
    dev_address : felt
):
    if caller != _dev_address.read() or caller != owner.read():
        revert("dev and owner only")
    end
    _dev_address.write(dev_address)
    return()
end
