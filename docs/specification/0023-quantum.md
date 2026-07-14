# Language Specification: Quantum Computing

## Overview

Quantum computing features provide a classical simulator accessible via `import std.quantum`. The simulation supports up to 16 qubits with a state-vector representation (65,536 complex amplitudes). Gates are applied as function calls that delegate to C runtime functions operating on the global state vector.

---

## 1. Import

**Decision: Module-based quantum via `import std.quantum`.**

```nizam
import std.quantum
```

Nine symbols are injected into scope:

| Symbol | Kind | Returns |
|--------|------|---------|
| `qbit` | Type / Function | `QBit` |
| `qreg` | Function | `QReg` |
| `H` | Function | `QBit` |
| `X` | Function | `QBit` |
| `Y` | Function | `QBit` |
| `Z` | Function | `QBit` |
| `CNOT` | Function | `Void` |
| `measure` | Function | `Void` |

Selective import is supported:

```nizam
from std.quantum import H, measure
```

---

## 2. Types

### 2.1 QBit

Represents a single qubit index.

```zig
// types.zig:48-49
QBit, QReg,
```

| Property | Value |
|----------|-------|
| LLVM type | `i32` |
| Size | 4 bytes |
| Alignment | 4 bytes |
| Copy/Move | **Copy** (trivially copyable) |
| ABI | **Direct** (passed in register) |

### 2.2 QReg

Represents a quantum register — a collection of contiguous qubits.

```zig
// types.zig — QReg layout
QReg → { ptr, i32 }   // 16 bytes on x86_64
```

| Property | Value |
|----------|-------|
| LLVM type | `{ ptr, i32 }` |
| Size | 16 bytes |
| Alignment | 8 bytes |
| Copy/Move | **Copy** (trivially copyable) |

---

## 3. Quantum Simulator Runtime (C)

**File:** `runtime.c:56-152`

### 3.1 State Vector

```c
#define MAX_QUBITS 16
#define NUM_STATES (1 << MAX_QUBITS)   // 65536

typedef struct {
    double real;
    double imag;
} Complex;

static Complex global_state[NUM_STATES];
static int active_qubits = 0;
```

A single global state vector represents the full quantum state. The simulator is limited to 16 qubits (2^16 = 65,536 complex amplitudes).

### 3.2 Qubit Allocation — `quantum_qreg`

```c
QReg quantum_qreg(int num) {
    if (active_qubits + num > MAX_QUBITS) {
        exit(1);  // "Maximum of 16 qubits exceeded."
    }
    if (active_qubits == 0) {
        // Initialize to |0...0⟩
        global_state[0].real = 1.0;
    }
    active_qubits += num;
    return (QReg){ .ptr = NULL, .num_qubits = num };
}
```

Allocates `num` qubits starting from the next available index. Total qubits across all registers must not exceed 16.

### 3.3 Hadamard Gate — `quantum_H`

```llvm
declare i32 @quantum_H(i32)
```

```c
int quantum_H(int target) {
    double inv_sqrt2 = 1.0 / sqrt(2.0);
    for (int i = 0; i < NUM_STATES; i++) {
        if ((i & (1 << target)) == 0) {
            int j = i | (1 << target);
            Complex a = global_state[i];
            Complex b = global_state[j];
            global_state[i].real = (a.real + b.real) * inv_sqrt2;
            global_state[i].imag = (a.imag + b.imag) * inv_sqrt2;
            global_state[j].real = (a.real - b.real) * inv_sqrt2;
            global_state[j].imag = (a.imag - b.imag) * inv_sqrt2;
        }
    }
    return target;
}
```

Applies the Hadamard matrix to create superposition. Returns the qubit index for chaining.

### 3.4 CNOT Gate — `quantum_CNOT`

```llvm
declare void @quantum_CNOT(i32, i32)
```

```c
void quantum_CNOT(int control, int target) {
    for (int i = 0; i < NUM_STATES; i++) {
        if ((i & (1 << control)) != 0 && (i & (1 << target)) == 0) {
            int j = i | (1 << target);
            Complex temp = global_state[i];
            global_state[i] = global_state[j];
            global_state[j] = temp;
        }
    }
}
```

Conditional XOR — entangles control and target qubits by swapping amplitude pairs where control is `|1⟩` and target is `|0⟩`.

### 3.5 Measurement — `quantum_measure`

```llvm
declare void @quantum_measure(i32)
```

```c
void quantum_measure(int target) {
    // Compute Prob(|1⟩)
    double prob_1 = 0.0;
    for (int i = 0; i < NUM_STATES; i++) {
        if (i & (1 << target)) {
            prob_1 += |global_state[i]|^2;
        }
    }
    // Sample based on Born rule
    double r = (double)rand() / RAND_MAX;
    int result = (r < prob_1) ? 1 : 0;

    // Collapse: normalize post-measurement state
    double norm = 1.0 / sqrt(result == 1 ? prob_1 : 1.0 - prob_1);
    for (int i = 0; i < NUM_STATES; i++) {
        int bit = (i & (1 << target)) ? 1 : 0;
        if (bit == result) {
            global_state[i].real *= norm;
            global_state[i].imag *= norm;
        } else {
            global_state[i] = (Complex){ 0.0, 0.0 };
        }
    }
}
```

Full Born-rule measurement: computes `Prob(|1⟩)`, samples via `rand()`, collapses the state vector to the measured outcome.

---

## 4. Type Inference

**File:** `typecheck.zig:836-841, 891`

| Function | Return Type |
|----------|-------------|
| `qbit(x)` | `QBit` |
| `H(x)` | `QBit` |
| `X(x)` | `QBit` |
| `Y(x)` | `QBit` |
| `Z(x)` | `QBit` |
| `qreg(n)` | `QReg` |
| `CNOT(ctrl, tgt)` | `Void` |
| `measure(qb)` | `Void` |

---

## 5. Codegen — LLVM IR

**File:** `codegen.zig:3293-3308`

| Mantiq Call | LLVM IR |
|-------------|---------|
| `H(qb)` | `%t = call i32 @quantum_H(i32 %qb)` |
| `CNOT(c, t)` | `call void @quantum_CNOT(i32 %c, i32 %t)` |
| `measure(qb)` | `call void @quantum_measure(i32 %qb)` |
| `qreg(n)` | `%t = call { ptr, i32 } @quantum_qreg(i32 %n)` |

---

## 6. Bra-Ket Notation

**Grammar** (`grammar.js:520`):

```js
quantum_literal: $ => seq('|', choice('0', '1'), '>')
```

```nizam
let qb as qbit = H(|0>)   // parse recognized but lowering not implemented
```

Valid primary expression (`|0>`, `|1>`), recognized by the parser but **not lowered** to an AST node. A future enhancement will lower these to integer literals (0, 1) or direct state initialization.

---

## 7. Dead Code Elimination — Quantum Tree Shaking

**Decision: Unused quantum imports are completely pruned (zero-cost abstraction).**

**File:** `dce.zig`

The DCE pass tracks whether any quantum symbols are used:

```zig
quantum_used: bool = false,

// Marked true on:
// - VarDecl with qbit/qreg type
// - CallExpr with H/measure name
// - Identifier with qbit/qreg name
```

If `quantum_used == false` after marking, the entire `import std.quantum` declaration is removed:

```zig
if (std.mem.eql(u8, target, "std.quantum") and !self.quantum_used) {
    continue;  // Prune unused quantum import
}
```

---

## 8. Missing Gates (X, Y, Z)

`X`, `Y`, `Z` are registered as built-in functions and type-checked, but have **no codegen emission** and **no C runtime implementation**. Calling them will produce a linker error.

---

## 9. AOT Linking

**File:** `aot.zig:81-82`

```zig
try args.append("-Wl,-z,undefs");
```

Native executables use `-Wl,-z,undefs` to allow unresolved quantum runtime symbols (resolved via the linked C runtime).

---

## 10. Examples

### Bell State Creation

```nizam
import std.quantum

fn main():
    let qb1 as qbit = H(0)
    let qb2 as qbit = H(1)
    CNOT(qb1, qb2)
    measure(qb1)
    measure(qb2)
    let entangled as qreg = qreg(2)
```

Creates the Bell state `|Φ⁺⟩ = (|00⟩ + |11⟩) / √2`, measures both qubits, and allocates a 2-qubit register.

### Quantum Register

```nizam
import std.quantum

let entangled = qreg(2)
H(entangled[0])
CNOT(entangled[0], entangled[1])
```

### Selective Import

```nizam
from std.quantum import H, measure

let qb = H(0)
measure(qb)
```

### Dead Quantum Code (Pruned)

```nizam
import std.quantum

fn main():
    if False:
        let qb as qbit = H(0)
        measure(qb)
// std.quantum is pruned: no quantum code reaches codegen
```

---

## 11. Limitations

| Limitation | Impact | Future Fix |
|------------|--------|------------|
| 16-qubit max | Cannot simulate larger circuits | Dynamic state vector allocation |
| Single global state | No independent circuit isolation | Per-context state vectors |
| No noise model | Ideal simulation only | Add decoherence / gate error models |
| No X/Y/Z gates | Missing Pauli gates | Implement runtime + codegen |
| Bra-ket lowering | `|0>` parsed but not compiled | Lower to integer literal 0 |
| No qreg indexing | `entangled[0]` not implemented | Direct qubit indexing |
| No quantum error correction | No QEC primitives | Syndrome measurement, correction |
| `rand()`-based sampling | Not cryptographically random | Use CSPRNG or hardware RNG |

---

## 12. Relevant Files

| File | Lines | Role |
|------|-------|------|
| `grammar.js` | 506, 520 | `quantum_literal` (`|0>`, `|1>`) syntax |
| `types.zig` | 48-49, 177-178, 245, 343 | `QBit`, `QReg` type kinds |
| `layout.zig` | 106-107, 201-202 | QBit=4/4, QReg=16/8 |
| `abi.zig` | 39, 69 | QBit Direct ABI |
| `sema.zig` | 293-303 | `std.quantum` built-in injection (9 symbols) |
| `typecheck.zig` | 133, 836-841, 891 | Quantum type inference |
| `codegen.zig` | 169-170, 375-378, 895-896, 3293-3308 | LLVM IR declarations and emission |
| `runtime.c` | 56-152 | Full quantum simulator (state vector, H, CNOT, measure, qreg) |
| `dce.zig` | 6, 38-41, 89-94, 113-117, 133-137 | Quantum tree shaking (zero-cost) |
| `aot.zig` | 81-82 | `-Wl,-z,undefs` for unresolved quantum symbols |
| `main.zig` | 123-143, 160-169, 271-283, 1326-1330 | Integration tests for quantum |
| `tests.zig` | 73-76, 165, 218-221, 411-415, 453-457 | Unit tests for quantum types/layout |
