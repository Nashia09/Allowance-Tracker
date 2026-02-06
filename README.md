# 💰 Allowance Tracker

A Clarity smart contract for managing parent-child allowances on the Stacks blockchain. Track spending, authorize children, and manage allowance distributions with built-in permission logic.

## 🎯 Features

- **Parent Authorization**: Parents authorize child accounts with customized allowances
- **Spending Tracking**: Monitor how much of the allowance has been spent
- **Permission Logic**: Only authorized children can spend; parents control who has access
- **Allowance Management**: Set, reset, and revoke allowances dynamically
- **Mapping Relationships**: Use maps to maintain parent-child relationships with multi-key lookups

## 📋 Core Functions

### Parent Functions

**`authorize-child(child: principal)`**
- Authorize a child account to receive an allowance
- Returns `true` on success
- Error if child is already authorized

**`set-allowance(child: principal, amount: uint)`**
- Set or update the allowance amount for an authorized child
- Only callable by the parent
- Returns `ok` on success

**`revoke-child(child: principal)`**
- Remove a child's authorization and reset their allowance
- Returns `ok` on success

**`reset-spending(child: principal)`**
- Reset the spent amount back to zero (monthly/periodic reset)
- Parent-only operation
- Returns `ok` on success

### Child Functions

**`spend-allowance(parent: principal, amount: uint)`**
- Child spends from their allowance
- Validates authorization and sufficient balance
- Returns `ok` on success
- Errors: not authorized, insufficient allowance

### Query Functions

**`get-allowance(parent: principal, child: principal)`**
- Returns the allowance data tuple (amount, spent, active)

**`get-remaining(parent: principal, child: principal)`**
- Returns remaining balance as `(ok amount)` or error

**`get-allowance-summary(parent: principal, child: principal)`**
- Returns detailed summary: total, spent, remaining, active status

**`is-authorized(parent: principal, child: principal)`**
- Boolean check if child is authorized

**`is-allowance-active(parent: principal, child: principal)`**
- Boolean check if allowance is active

**`get-children(parent: principal)`**
- Returns list of all authorized children for a parent

## 🚀 Usage Example

```clarity
(contract-call? .allowance authorize-child 'ST2F4BK4GZH6IXKNLVNOKY3F6YK6T5FNFYX3G4XY)

(contract-call? .allowance set-allowance 'ST2F4BK4GZH6IXKNLVNOKY3F6YK6T5FNFYX3G4XY u10000)

(contract-call? .allowance spend-allowance 'STQF4WRXEKBZ5Q9SDBZHSFWYHY3KXNCH6E5FKK3 u1000)

(contract-call? .allowance get-allowance-summary 'STQF4WRXEKBZ5Q9SDBZHSFWYHY3KXNCH6E5FKK3 'ST2F4BK4GZH6IXKNLVNOKY3F6YK6T5FNFYX3G4XY)
```

## 🔒 Permission Model

- **Parents**: Full control over authorizing children and setting allowance amounts
- **Children**: Can only spend their authorized allowance
- **Authorization**: Must be granted before any allowance operations
- **Error Handling**: Proper error codes for unauthorized access (401), insufficient balance (402), and missing records (404)

## 📦 Data Structures

**Allowance Data Map**
- Key: `{ parent, child }`
- Value: `{ amount, spent, active }`

**Authorizations Map**
- Key: `{ parent, child }`
- Value: `{ created-at, created-by }`

**Parent-Children Map**
- Key: `{ parent }`
- Value: `{ children: [list of principals] }`

## 🛠️ Error Codes

| Code | Name | Meaning |
|------|------|---------|
| 401 | ERR-UNAUTHORIZED | Caller lacks required permissions |
| 402 | ERR-INSUFFICIENT-ALLOWANCE | Not enough allowance to spend |
| 404 | ERR-NOT-FOUND | Record does not exist |
| 409 | ERR-ALREADY-AUTHORIZED | Child already authorized |

## 🧪 Testing

```bash
npm test
```

## ✨ Key Teaching Points

This contract teaches:
- **Map operations**: Multi-key maps for storing relationships
- **Permission logic**: Checking authorization before allowing actions
- **Data integrity**: Maintaining consistency across multiple maps
- **Error handling**: Proper error propagation and validation
- **Transaction semantics**: How parents and children interact through contract calls
